defmodule Longx.Agent.Plugs.Shell do
  @moduledoc """
  codex's `exec_command`: a shell command run in the working directory
  through `Longx.Shim`, in the person's own shell with the environment
  of their interactive login shell (`Longx.Agent.Tools.ShellEnv`) — output
  streamed to the UI as it comes, the whole tree killed at the timeout. The parameters are codex's (`cmd`,
  `workdir`, `tty`, `yield_time_ms`, `max_output_tokens`, `shell`, `login`)
  so models tuned for codex call it the same way; the difference is that
  a command runs to completion here (up to `timeout_ms`, default 2 min,
  max 30 min) — `yield_time_ms` / `write_stdin` sessions are not offered
  yet. No sandbox: the kernel runs on the person's machine as the person
  (isolation, when wanted, is the deployment's job) — but **the machine is
  guarded** (the settings' command guards, given as the plug's options by
  the loader's settings layer): `oom_score_adj:` for the command's tree so
  the kernel kills it before anything else, `memory_percent:` (or
  `memory_limit:` in bytes) as the tree's address-space cap, and
  `memory_floor_percent:`: the command registers with `Longx.System.Pressure`
  and is killed when free memory falls under that share. The tool's
  description tells the model the limits so it splits heavy work instead of
  looping it.

  The model reads codex's `format_exec_output_for_model` shape (its
  `core/src/tools/mod.rs`): `Exit code:`, `Wall time:`, `Total output
  lines:` when clipped, then `Output:` and stdout + stderr interleaved as
  they arrived, capped by `max_output_tokens` (10 000 by default, ~4 bytes a
  token: the head and the tail kept around codex's `…N tokens truncated…`
  marker). A timeout is codex's "command timed out after N milliseconds"
  as the body's first line with exit code 124; a kill (the person, memory
  pressure) the same way with 137 — `{:error, text, extra}`, the `reason`
  in `extra` being what the page appends to the streamed output.
  """

  use Longx.Agent.Plug

  alias Longx.Agent.Tools.ShellEnv
  alias Longx.Shim

  @default_timeout 120_000
  @max_timeout 30 * 60_000
  @default_output_tokens 10_000
  @bytes_per_token 4
  @emit_cap 256 * 1024

  tool :exec_command,
       "Runs a shell command in the working directory and returns its output (stdout and stderr interleaved) and exit code. The command runs to completion; it is killed after timeout_ms (default 120000, max 1800000). Long-running servers should be started in the background (nohup … &).",
       show: :command,
       timeout: @max_timeout + 5_000,
       prepare: &__MODULE__.normalize/1 do
    param :cmd, :string, "Shell command to execute.", required: true
    param :workdir, :string, "Working directory for the command. Defaults to the turn cwd."

    param :tty,
          :boolean,
          "True allocates a PTY for the command; false or omitted uses plain pipes."

    param :yield_time_ms,
          :number,
          "Accepted for compatibility; the command runs to completion here."

    param :max_output_tokens, :number, "Output token budget. Defaults to 10000 tokens."

    param :timeout_ms,
          :integer,
          "Kill the command after this many milliseconds (default 120000, max 1800000)."

    param :shell, :string, "Shell binary to launch. Defaults to the user's default shell."

    param :login,
          :boolean,
          "True runs the shell with -l semantics; false disables them. Defaults to true."
  end

  @impl true
  def init(opts), do: opts

  # the tool mounted with the guards the options name: a closure carrying them,
  # the description saying what they are (a note the model can act on)
  @impl true
  def call(%Step{phase: :request} = step, opts) do
    guards = guards(opts)
    tool = Enum.find(__agent_tools__(), &(&1.name == "exec_command"))

    tool = %{
      tool
      | fun: fn args, ctx -> exec_command(args, ctx, guards) end,
        description:
          String.replace(
            tool.description,
            "default #{@default_timeout}",
            "default #{guards.timeout}"
          ) <>
            guard_note(guards)
    }

    step
    |> Longx.Agent.Plug.mount(__MODULE__)
    |> Step.tool(tool)
  end

  def call(step, _opts), do: step

  @doc false
  def guards(opts) do
    total = Longx.System.Memory.total()
    percent = Keyword.get(opts, :memory_percent)

    limit =
      cond do
        is_integer(opts[:memory_limit]) and opts[:memory_limit] > 0 -> opts[:memory_limit]
        is_integer(percent) and percent > 0 and is_integer(total) -> div(total * percent, 100)
        true -> nil
      end

    oom = Keyword.get(opts, :oom_score_adj)
    floor = Keyword.get(opts, :memory_floor_percent, 0)

    %{
      oom_score_adj: if(is_integer(oom) and oom > 0, do: oom),
      memory_limit: limit,
      floor: if(is_integer(floor) and floor > 0 and is_integer(total), do: floor, else: 0),
      # `options Shell, timeout_ms:` — a description's default for every command (capped)
      timeout: timeout(Keyword.get(opts, :timeout_ms), @default_timeout)
    }
  end

  defp guard_note(%{memory_limit: nil, floor: 0}), do: ""

  defp guard_note(%{memory_limit: limit, floor: floor}) do
    lines =
      [
        limit &&
          "a command may use at most #{Longx.System.Pressure.human(limit)} of address space (allocations past it fail)",
        floor > 0 &&
          "when the machine's free memory drops below #{floor}% every running command is killed"
      ]
      |> Enum.filter(& &1)

    " Limits: " <>
      Enum.join(lines, "; ") <>
      ". Split heavy jobs (backtests, training, big data loads) into small runs and check each one; never a loop of them in one command."
  end

  def exec_command(args, ctx), do: exec_command(args, ctx, guards([]))

  @doc """
  The tool's `prepare:`: codex's own exec_command arguments object wrapped
  under `cmd` by the model (`{"cmd": {"cmd": "…", "yield_time_ms": 1000}}` —
  gpt-5.6 through the Codex backend did it once) is unwrapped, the outer keys
  kept where the inner ones do not say otherwise.
  """
  def normalize(%{"cmd" => %{"cmd" => _} = inner} = args) when is_map(args),
    do: Map.merge(Map.delete(args, "cmd"), inner)

  def normalize(args), do: args

  @doc false
  def exec_command(%{"cmd" => command} = args, ctx, guards) do
    timeout = timeout(args["timeout_ms"], guards.timeout)
    cwd = workdir(args["workdir"], ctx)

    shell =
      if is_binary(args["shell"]) and args["shell"] != "",
        do: args["shell"],
        else: ShellEnv.shell()

    flag = if args["login"] == false, do: "-c", else: "-lc"
    tty? = args["tty"] == true
    max_bytes = output_cap(args["max_output_tokens"])
    started = System.monotonic_time(:millisecond)

    # the person's own shell environment (a snapshot of their interactive login
    # shell), nothing of the BEAM's: Go, brew, nvm are where their .zshrc put them
    # no pipe for stdin without a tty: the null device, as codex spawns its
    # exec_command (`spawn_process_no_stdin`) — ripgrep with no path searches a
    # piped stdin instead of the directory, and an agent's `rg pattern` found
    # nothing in the empty pipe
    opts =
      [cd: cwd, env: ShellEnv.env_list(), env_clear: true] ++
        if(tty?, do: [pty: true], else: [stderr: :stream, stdin: :null]) ++
        if(guards.oom_score_adj, do: [oom_score_adj: guards.oom_score_adj], else: []) ++
        if(guards.memory_limit, do: [memory_limit: guards.memory_limit], else: [])

    # the watchdog and the settings page know this command before it starts
    # (`Longx.System.Commands`); the entry dies with this process
    :ok =
      Longx.System.Pressure.register(%{
        id: "cmd_" <> Ash.UUID.generate(),
        shim: nil,
        floor: guards.floor,
        cmd: command,
        thread_id: ctx.thread_id,
        started_at: System.system_time(:millisecond)
      })

    case Shim.start_link([shell, flag, command], opts) do
      {:ok, shim} ->
        # the ledger gets the shim and the OS pid: what the settings page shows and kills
        Longx.System.Pressure.update(%{shim: shim, os_pid: Shim.os_pid(shim)})

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
            {:ok, report(acc, code, started, max_bytes, nil),
             %{"exitCode" => code, "durationMs" => elapsed(started)}}

          # codex's words and its conventional exit code for a timeout
          {:timeout, acc} ->
            Shim.kill(shim)
            reason = "command timed out after #{timeout} milliseconds"

            {:error, report(acc, 124, started, max_bytes, reason),
             %{"exitCode" => 124, "durationMs" => elapsed(started), "reason" => reason}}

          {:killed, acc} ->
            Shim.kill(shim)

            reason =
              "killed from the settings page by the person (it was taking too long or hanging). " <>
                "Do not run it again as it was; ask what to do next or take a smaller step."

            {:error, report(acc, 137, started, max_bytes, reason),
             %{"exitCode" => 137, "durationMs" => elapsed(started), "reason" => reason}}

          {:pressure, %{percent: percent, available: available, total: total}, acc} ->
            Shim.kill(shim)

            reason =
              "killed by Longx: the machine was down to #{percent}% free memory " <>
                "(#{Longx.System.Pressure.human(available)} of #{Longx.System.Pressure.human(total)}). " <>
                "Run a smaller job (fewer rows, a smaller batch, one run at a time) and check its memory before going bigger."

            {:error, report(acc, 137, started, max_bytes, reason),
             %{"exitCode" => 137, "durationMs" => elapsed(started), "reason" => reason}}
        end

      {:error, reason} ->
        {:error, "could not start the command: #{inspect(reason)}"}
    end
  end

  defp workdir(dir, ctx) when is_binary(dir) and dir != "", do: Context.path(ctx, dir)
  defp workdir(_dir, ctx), do: ctx.cwd || File.cwd!()

  defp timeout(ms, _default) when is_integer(ms) and ms > 0, do: min(ms, @max_timeout)
  defp timeout(_, default), do: default

  defp output_cap(tokens) when is_number(tokens) and tokens > 0,
    do: trunc(tokens) * @bytes_per_token

  defp output_cap(_), do: @default_output_tokens * @bytes_per_token

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

      {:memory_pressure, reading} ->
        {:pressure, reading, acc}

      {:kill_command, _by} ->
        {:killed, acc}
    after
      max(remaining, 0) -> {:timeout, acc}
    end
  end

  defp keep(%{output: out, size: size} = acc, data),
    do: %{acc | output: [out, data], size: size + byte_size(data)}

  defp show(%{emitted: emitted} = acc, ctx, data) when emitted < @emit_cap do
    Context.emit(ctx, Longx.Agent.Text.utf8(data))
    %{acc | emitted: emitted + byte_size(data)}
  end

  defp show(%{emitted: @emit_cap} = acc, ctx, _data) do
    Context.emit(ctx, "\n[output truncated]\n")
    %{acc | emitted: @emit_cap + 1}
  end

  defp show(acc, _ctx, _data), do: acc

  # what the model reads is codex's `format_exec_output_for_model` (core/src/tools/mod.rs):
  # the exit code, the wall time, the line count when the body was clipped,
  # then the output — a timeout or a kill as the first line of the body, as
  # codex writes a timeout
  defp report(acc, code, started, max_bytes, reason) do
    whole = IO.iodata_to_binary(acc.output)
    body = if reason, do: reason <> "\n" <> whole, else: whole
    {clipped, clipped?} = clip(body, max_bytes)
    seconds = Float.round(elapsed(started) / 1000, 1)

    header =
      ["Exit code: #{code}", "Wall time: #{seconds} seconds"] ++
        if(clipped?, do: ["Total output lines: #{line_count(body)}"], else: []) ++
        ["Output:"]

    Enum.join(header, "\n") <> "\n" <> clipped
  end

  defp line_count(text), do: text |> String.split("\n") |> Enum.reject(&(&1 == "")) |> length()

  # the head and the tail are kept whole; the middle is dropped once past the cap
  # with codex's marker (its unit is tokens, ~4 bytes each)
  defp clip(whole, max_bytes) do
    size = byte_size(whole)

    # scrubbed after the clip: the cut may fall inside a multibyte character,
    # and the output may not have been UTF-8 to begin with
    if size > max_bytes do
      half = div(max_bytes, 2)

      {Longx.Agent.Text.utf8(
         binary_part(whole, 0, half) <>
           "\n…#{div(size - max_bytes, 4)} tokens truncated…\n" <>
           binary_part(whole, size - half, half)
       ), true}
    else
      {Longx.Agent.Text.utf8(whole), false}
    end
  end

  defp elapsed(started), do: System.monotonic_time(:millisecond) - started
end
