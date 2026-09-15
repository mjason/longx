defmodule Longx.Exec.Process do
  @moduledoc """
  One command started by codex through the exec-server, over `Longx.Shim`
  (so it gets the shim's tree kill, resource guards, and a pseudo-terminal
  when codex asks for `tty` — then the one stream is `pty` and stdin stays
  open for `process/write`).

  Mirrors the process half of codex's own executor: every piece of output,
  the exit and the close each take the next number of one sequence and go
  out as a `process/output` / `process/exited` / `process/closed`
  notification to `notify:` (the session), and are kept — up to 1 MiB —
  for `process/read`, which can wait for something new. `process/closed`
  comes once both streams hit EOF *and* the exit is known; a read answers
  `closed` then and codex stops polling.

  The process is linked to the session: a closed connection takes every
  command with it (the shim kills the whole tree).
  """

  use GenServer

  alias Longx.Shim

  require Logger

  @retain_bytes 1024 * 1024
  @retain_chunks 50_000
  @kill_grace_ms 2_000
  @exit_settle_ms 200
  @denial_words [
    "operation not permitted",
    "permission denied",
    "read-only file system",
    "seccomp",
    "sandbox",
    "landlock",
    "failed to write file"
  ]

  defstruct [
    :id,
    :shim,
    :notify,
    :sandbox,
    :tty?,
    seq: 1,
    chunks: [],
    bytes: 0,
    exit_code: nil,
    open_streams: 2,
    closed?: false,
    stdin_open?: false,
    write_ids: %{},
    waiters: [],
    output: [],
    denied?: false,
    pending_exit: nil,
    pumps: %{},
    waiter: nil
  ]

  @typedoc """
  `id:` codex's process id; `argv:`, `cwd:`, `env:` (a map); `tty:` /
  `pipe_stdin:` (stdin stays open); `sandbox:` the kind the command runs
  under (for the denial heuristic); `notify:` where events go; `shim:`
  extra `Longx.Shim` options (resource guards).
  """
  @type spec :: keyword

  @spec start_link(spec) :: GenServer.on_start()
  def start_link(spec), do: GenServer.start_link(__MODULE__, spec)

  @doc "codex's `process/read`: retained output after `after_seq`, at most `max_bytes`, waiting up to `wait_ms` for something new."
  @spec read(GenServer.server(), non_neg_integer, pos_integer | nil, non_neg_integer) ::
          {:ok, map}
  def read(server, after_seq, max_bytes, wait_ms),
    do: GenServer.call(server, {:read, after_seq, max_bytes, wait_ms}, :infinity)

  @doc "codex's `process/write`: stdin bytes, once per `write_id`."
  @spec write(GenServer.server(), binary, String.t()) :: :accepted | :stdin_closed
  def write(server, data, write_id), do: GenServer.call(server, {:write, data, write_id})

  @doc "codex's `process/signal` (only `interrupt` exists)."
  @spec signal(GenServer.server(), :interrupt) :: :ok
  def signal(server, :interrupt), do: GenServer.call(server, {:signal, :int})

  @doc "codex's `process/terminate`; whether the process was still running."
  @spec terminate(GenServer.server()) :: boolean
  def terminate(server), do: GenServer.call(server, :terminate)

  @doc """
  codex's `is_likely_sandbox_denied`: a non-zero exit of a sandboxed
  command whose output mentions a denial, or a seccomp kill (128 + SIGSYS);
  "not found" / usage exits (2, 126, 127) are not denials.
  """
  @spec sandbox_denied?(Longx.Exec.Sandbox.kind(), integer, binary) :: boolean
  def sandbox_denied?(:none, _code, _output), do: false
  def sandbox_denied?(_kind, 0, _output), do: false

  def sandbox_denied?(kind, code, output) do
    lower = String.downcase(output)

    cond do
      Enum.any?(@denial_words, &String.contains?(lower, &1)) -> true
      code in [2, 126, 127] -> false
      kind == :bwrap and code == 128 + 31 -> true
      true -> false
    end
  end

  ## Server

  @impl true
  def init(spec) do
    Process.flag(:trap_exit, true)
    tty? = Keyword.get(spec, :tty, false)
    stdin_open? = tty? or Keyword.get(spec, :pipe_stdin, false)
    env = for {k, v} <- Keyword.get(spec, :env, %{}), do: {k, v}

    shim_opts =
      [
        cd: Keyword.fetch!(spec, :cwd),
        env: env,
        env_clear: true,
        stderr: :stream,
        grace: @kill_grace_ms,
        pty: tty?
      ] ++
        Keyword.get(spec, :shim, [])

    case Shim.start_link(Keyword.fetch!(spec, :argv), shim_opts) do
      {:ok, shim} ->
        unless stdin_open?, do: Shim.close_stdin(shim)
        me = self()

        out =
          spawn_link(fn -> pump(shim, &Shim.read/3, if(tty?, do: "pty", else: "stdout"), me) end)

        err = spawn_link(fn -> pump(shim, &Shim.read_stderr/3, "stderr", me) end)

        waiter =
          spawn_link(fn ->
            send(me, {:exited, Shim.await_exit(shim, :infinity, close_streams: false)})
          end)

        {:ok,
         %__MODULE__{
           id: Keyword.fetch!(spec, :id),
           shim: shim,
           notify: Keyword.fetch!(spec, :notify),
           sandbox: Keyword.get(spec, :sandbox, :none),
           tty?: tty?,
           stdin_open?: stdin_open?,
           pumps: %{out => if(tty?, do: "pty", else: "stdout"), err => "stderr"},
           waiter: waiter
         }}

      {:error, reason} ->
        {:stop, {:start_failed, reason}}
    end
  end

  defp pump(shim, reader, stream, server) do
    case reader.(shim, Longx.Shim.Proto.max_chunk(), :infinity) do
      {:ok, data} ->
        send(server, {:chunk, stream, data})
        pump(shim, reader, stream, server)

      _eof_or_closed ->
        send(server, {:stream_eof, stream})
    end
  end

  @impl true
  def handle_call({:read, after_seq, max_bytes, wait_ms}, from, state) do
    case answer(state, after_seq, max_bytes) do
      {:reply, response} ->
        {:reply, {:ok, response}, state}

      :wait when wait_ms > 0 ->
        ref = make_ref()
        Process.send_after(self(), {:read_deadline, ref}, wait_ms)
        {:noreply, %{state | waiters: [{ref, from, after_seq, max_bytes} | state.waiters]}}

      :wait ->
        {:reply, {:ok, response(state, after_seq, max_bytes)}, state}
    end
  end

  def handle_call({:write, _data, _id}, _from, %{stdin_open?: false} = state),
    do: {:reply, :stdin_closed, state}

  def handle_call({:write, data, write_id}, _from, state) do
    if Map.has_key?(state.write_ids, write_id) do
      {:reply, :accepted, state}
    else
      case Shim.write(state.shim, data) do
        :ok -> {:reply, :accepted, %{state | write_ids: Map.put(state.write_ids, write_id, true)}}
        {:error, :closed} -> {:reply, :stdin_closed, %{state | stdin_open?: false}}
      end
    end
  end

  def handle_call({:signal, sig}, _from, %{exit_code: nil} = state) do
    Shim.signal(state.shim, sig)
    {:reply, :ok, state}
  end

  def handle_call({:signal, _sig}, _from, state), do: {:reply, :ok, state}

  def handle_call(:terminate, _from, %{exit_code: nil} = state) do
    Shim.kill(state.shim, @kill_grace_ms)
    {:reply, true, state}
  end

  def handle_call(:terminate, _from, state), do: {:reply, false, state}

  @impl true
  def handle_info({:chunk, stream, data}, state) do
    {seq, state} = next_seq(state)
    chunk = %{"seq" => seq, "stream" => stream, "chunk" => Base.encode64(data)}

    state =
      %{
        state
        | chunks: [chunk | state.chunks],
          bytes: state.bytes + byte_size(data),
          output: [data | state.output]
      }
      |> evict()
      |> emit("process/output", chunk)

    {:noreply, wake(state)}
  end

  def handle_info({:stream_eof, stream}, state) do
    state =
      state
      |> Map.update!(:open_streams, &max(&1 - 1, 0))
      |> Map.update!(:pumps, &Map.reject(&1, fn {_, name} -> name == stream end))

    case state do
      %{open_streams: 0, pending_exit: code} when is_integer(code) ->
        {:noreply, exited(%{state | pending_exit: nil}, code)}

      _ ->
        {:noreply, maybe_close(state)}
    end
  end

  # the exit status can arrive before the last output does (the pipes still
  # hold bytes): give the streams a moment so the output keeps its place
  # before the exit — and a sandboxed command's denial is read off it
  # (codex waits 20 ms too) — unless they are already done
  def handle_info({:exited, result}, state) do
    code =
      case result do
        {:ok, status} ->
          status

        {:error, reason} ->
          Logger.warning("exec: #{state.id} exit unknown: #{inspect(reason)}")
          -1
      end

    if state.open_streams > 0 do
      Process.send_after(self(), {:finish_exit, code}, @exit_settle_ms)
      {:noreply, %{state | pending_exit: code}}
    else
      {:noreply, exited(state, code)}
    end
  end

  def handle_info({:finish_exit, code}, %{pending_exit: code} = state),
    do: {:noreply, exited(%{state | pending_exit: nil}, code)}

  def handle_info({:finish_exit, _code}, state), do: {:noreply, state}

  def handle_info({:read_deadline, ref}, state) do
    case List.keytake(state.waiters, ref, 0) do
      {{_, from, after_seq, max_bytes}, waiters} ->
        GenServer.reply(from, {:ok, response(state, after_seq, max_bytes)})
        {:noreply, %{state | waiters: waiters}}

      nil ->
        {:noreply, state}
    end
  end

  # The shim server stopping is not news by itself: it stops normally right
  # after it answered the waiter (which is on its way with the status), and
  # a crash reaches the waiter as an error — every exit comes through the
  # waiter. What can go wrong is a helper dying with its call: a pump that
  # never got its EOF, a waiter that never got to send.
  def handle_info({:EXIT, shim, _reason}, %{shim: shim} = state), do: {:noreply, state}

  def handle_info({:EXIT, pid, reason}, %{pumps: pumps} = state) when is_map_key(pumps, pid) do
    if reason != :normal,
      do: Logger.debug("exec: #{state.id} #{pumps[pid]} pump died: #{inspect(reason)}")

    handle_info({:stream_eof, pumps[pid]}, %{state | pumps: Map.delete(pumps, pid)})
  end

  def handle_info({:EXIT, waiter, reason}, %{waiter: waiter, exit_code: nil} = state)
      when reason != :normal do
    Logger.warning("exec: #{state.id} lost the exit status: #{inspect(reason)}")
    {:noreply, exited(state, -1)}
  end

  # the session is gone: nobody will read this any more, take the tree down
  def handle_info({:EXIT, notify, _reason}, %{notify: notify} = state),
    do: {:stop, :shutdown, state}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{exit_code: nil, shim: shim}) do
    try do
      Shim.kill(shim, @kill_grace_ms)
    catch
      :exit, _ -> :ok
    end
  end

  def terminate(_reason, _state), do: :ok

  defp exited(%{exit_code: nil} = state, code) do
    {seq, state} = next_seq(state)
    output = state.output |> Enum.reverse() |> IO.iodata_to_binary()
    denied? = sandbox_denied?(state.sandbox, code, output)

    %{state | exit_code: code, denied?: denied?}
    |> emit("process/exited", %{"seq" => seq, "exitCode" => code, "sandboxDenied" => denied?})
    |> wake()
    |> maybe_close()
  end

  defp exited(state, _code), do: state

  defp maybe_close(%{closed?: false, open_streams: 0, exit_code: code} = state)
       when is_integer(code) do
    {seq, state} = next_seq(state)
    %{state | closed?: true} |> emit("process/closed", %{"seq" => seq}) |> wake()
  end

  defp maybe_close(state), do: state

  defp next_seq(%{seq: seq} = state), do: {seq, %{state | seq: seq + 1}}

  defp emit(state, method, params) do
    send(state.notify, {:exec_process, state.id, method, Map.put(params, "processId", state.id)})
    state
  end

  defp evict(%{bytes: bytes, chunks: chunks} = state)
       when bytes > @retain_bytes or length(chunks) > @retain_chunks do
    [oldest | rest] = Enum.reverse(chunks)
    size = oldest["chunk"] |> Base.decode64!() |> byte_size()
    evict(%{state | chunks: Enum.reverse(rest), bytes: bytes - size})
  end

  defp evict(state), do: state

  # answer every waiting read that now has something to say
  defp wake(state) do
    {done, waiting} =
      Enum.split_with(state.waiters, fn {_, _, after_seq, max_bytes} ->
        match?({:reply, _}, answer(state, after_seq, max_bytes))
      end)

    for {_, from, after_seq, max_bytes} <- done,
        do: GenServer.reply(from, {:ok, response(state, after_seq, max_bytes)})

    %{state | waiters: waiting}
  end

  # codex: reply at once with chunks, on close, or on an exit newer than after_seq
  defp answer(state, after_seq, max_bytes) do
    response = response(state, after_seq, max_bytes)
    new_exit? = response["exited"] and after_seq < state.seq - 1

    if response["chunks"] != [] or response["closed"] or new_exit?,
      do: {:reply, response},
      else: :wait
  end

  defp response(state, after_seq, max_bytes) do
    {chunks, next_seq} =
      state.chunks
      |> Enum.reverse()
      |> Enum.filter(&(&1["seq"] > after_seq))
      |> take(max_bytes, state.seq)

    %{
      "chunks" => chunks,
      "nextSeq" => next_seq,
      "exited" => state.exit_code != nil,
      "exitCode" => state.exit_code,
      "closed" => state.closed?,
      "failure" => nil,
      "sandboxDenied" => state.denied?
    }
  end

  defp take(chunks, nil, next_seq), do: {chunks, next_seq}

  defp take(chunks, max_bytes, next_seq) do
    {taken, _} =
      Enum.reduce_while(chunks, {[], 0}, fn chunk, {acc, total} ->
        size = chunk["chunk"] |> Base.decode64!() |> byte_size()

        cond do
          acc != [] and total + size > max_bytes -> {:halt, {acc, total}}
          total + size >= max_bytes -> {:halt, {[chunk | acc], total + size}}
          true -> {:cont, {[chunk | acc], total + size}}
        end
      end)

    taken = Enum.reverse(taken)

    case taken do
      [] -> {[], next_seq}
      _ -> {taken, List.last(taken)["seq"] + 1}
    end
  end
end
