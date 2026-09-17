defmodule Longx.Agent.Plugs.Shell do
  @moduledoc """
  The `exec` tool: a shell command run with `bash -lc` in the working
  directory through `Longx.Shim` — output streamed to the UI as it comes,
  the whole tree killed at the timeout. No sandbox: the kernel runs on
  the person's machine as the person (isolation, when wanted, is the
  deployment's job — the whole of Longx in a container).

  The model gets stdout and stderr interleaved as they arrived, capped to
  the head and tail (`max_output:` bytes, 128 KB) and the exit code when it
  is not zero. A timeout is an error carrying what was printed so far.
  """

  use Longx.Agent.Plug

  alias Longx.Shim

  @default_timeout 120_000
  @max_timeout 30 * 60_000
  @max_output 128 * 1024
  @emit_cap 256 * 1024

  tool :exec,
       "Runs a shell command with bash in the working directory and returns its output (stdout and stderr) and exit code. Long-running commands are killed at timeout_ms (default 120000, max 1800000).",
       show: :command,
       timeout: @max_timeout + 5_000 do
    param :command, :string, "The command line, run with `bash -lc`", required: true
    param :timeout_ms, :integer, "Kill the command after this many milliseconds"
  end

  def exec(%{"command" => command} = args, ctx) do
    timeout = args["timeout_ms"] |> timeout()
    cwd = ctx.cwd || File.cwd!()
    started = System.monotonic_time(:millisecond)

    case Shim.start_link(["bash", "-lc", command],
           cd: cwd,
           env: [{"TERM", "dumb"}],
           stderr: :stream
         ) do
      {:ok, shim} ->
        :ok = Shim.close_stdin(shim)
        me = self()
        spawn_link(fn -> pump(shim, &Shim.read/3, me) end)
        spawn_link(fn -> pump(shim, &Shim.read_stderr/3, me) end)

        spawn_link(fn ->
          send(me, {:exited, Shim.await_exit(shim, :infinity, close_streams: false)})
        end)

        deadline = started + timeout

        case collect(%{output: [], size: 0, emitted: 0, eofs: 0, exit: nil}, ctx, deadline) do
          {:ok, %{exit: code} = acc} ->
            {:ok, report(text(acc), code),
             %{"exitCode" => code, "durationMs" => elapsed(started)}}

          {:timeout, acc} ->
            Shim.kill(shim)
            {:error, "timed out after #{timeout} ms\n" <> text(acc)}
        end

      {:error, reason} ->
        {:error, "could not start the command: #{inspect(reason)}"}
    end
  end

  defp timeout(nil), do: @default_timeout
  defp timeout(ms) when is_integer(ms) and ms > 0, do: min(ms, @max_timeout)
  defp timeout(_), do: @default_timeout

  defp pump(shim, read, owner) do
    case read.(shim, 65_536, :infinity) do
      {:ok, data} ->
        send(owner, {:out, data})
        pump(shim, read, owner)

      _eof_or_error ->
        send(owner, :eof)
    end
  end

  # both streams at eof and the exit known → done; the deadline → timeout
  defp collect(%{eofs: 2, exit: code} = acc, _ctx, _deadline) when is_integer(code),
    do: {:ok, acc}

  defp collect(acc, ctx, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    receive do
      {:out, data} ->
        acc |> keep(data) |> show(ctx, data) |> collect(ctx, deadline)

      :eof ->
        collect(%{acc | eofs: acc.eofs + 1}, ctx, deadline)

      {:exited, {:ok, code}} ->
        collect(%{acc | exit: code}, ctx, deadline)

      {:exited, {:error, _}} ->
        collect(%{acc | exit: -1}, ctx, deadline)
    after
      max(remaining, 0) -> {:timeout, acc}
    end
  end

  # the head and the tail are kept whole; the middle is dropped once past the cap
  defp keep(%{output: out, size: size} = acc, data),
    do: %{acc | output: [out, data], size: size + byte_size(data)}

  defp show(%{emitted: emitted} = acc, ctx, data) when emitted < @emit_cap do
    Context.emit(ctx, data)
    %{acc | emitted: emitted + byte_size(data)}
  end

  defp show(%{emitted: @emit_cap} = acc, ctx, _data) do
    Context.emit(ctx, "\n[output truncated]\n")
    %{acc | emitted: @emit_cap + 1}
  end

  defp show(acc, _ctx, _data), do: acc

  defp text(%{output: out, size: size}) do
    whole = IO.iodata_to_binary(out)

    if size > @max_output do
      half = div(@max_output, 2)

      binary_part(whole, 0, half) <>
        "\n\n[... #{size - @max_output} bytes omitted ...]\n\n" <>
        binary_part(whole, size - half, half)
    else
      whole
    end
  end

  defp report(text, 0), do: text
  defp report(text, code), do: text <> "\n[exit code #{code}]"

  defp elapsed(started), do: System.monotonic_time(:millisecond) - started
end
