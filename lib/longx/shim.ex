defmodule Longx.Shim do
  @moduledoc """
  Runs an external program through the Go shim in `native/shim`, giving what a
  bare `Port` cannot:

    * **Back-pressure** — output is only read when you call `read/3`, input is
      only sent when the child is ready; neither side can flood the BEAM.
    * **Separate stderr** — `read_stderr/3`, instead of console or merged.
    * **Independent stdin close** — `close_stdin/1` while still reading.
    * **Clean termination** — `kill/2` SIGTERMs the child's whole process
      group and escalates to SIGKILL after a grace period; if this process (or
      the BEAM) dies the shim notices its stdin closing and does the same.

  The process that calls `start_link/2` is linked to the server. Any process
  may read/write, but at most one read may be pending per stream. Always
  finish with `await_exit/2`: it delivers the exit status, closes streams you
  did not drain, and lets the server stop.

      {:ok, shim} = Longx.Shim.start_link(["codex", "app-server"])
      :ok = Longx.Shim.write(shim, ~s({"id":1,"method":"initialize"}\\n))
      {:ok, line} = Longx.Shim.read(shim)
      :ok = Longx.Shim.kill(shim)
      {:ok, _status} = Longx.Shim.await_exit(shim)

  Design adapted from ex_cmd (MIT); see `NOTICE`.
  """

  use GenServer

  alias Longx.Shim.Proto

  require Logger

  @default_grace_ms 5_000
  @start_timeout 5_000
  @signals %{hup: 1, int: 2, kill: 9, term: 15}

  @type stderr_mode :: :stream | :console | :disable | :redirect_to_stdout
  @type option ::
          {:cd, Path.t()}
          | {:env,
             [{String.t() | atom, String.t()}] | %{optional(String.t() | atom) => String.t()}}
          | {:stderr, stderr_mode}
          | {:grace, non_neg_integer}
          | {:log, :stderr | Path.t()}
          | {:oom_score_adj, -1000..1000}
          | {:memory_limit, pos_integer}

  @type read_result :: {:ok, binary} | :eof | {:error, :pending_read | :closed}

  defmodule Stream do
    @moduledoc false
    defstruct status: :open, pending: nil
  end

  defmodule State do
    @moduledoc false
    defstruct [
      :port,
      :os_pid,
      :owner,
      credit: false,
      writes: :queue.new(),
      stdin: :open,
      stdout: %Longx.Shim.Stream{},
      stderr: %Longx.Shim.Stream{},
      exit_status: nil,
      exit_waiters: [],
      awaited?: false,
      shim_exited?: false,
      stats_waiters: []
    ]
  end

  ## Client

  @doc """
  Starts `cmd_with_args` under the shim. Fails without crashing the caller
  when the command cannot be found or `:cd` is not a directory.
  """
  @spec start_link([String.t(), ...], [option]) ::
          {:ok, pid}
          | {:error,
             {:command_not_found, String.t()}
             | {:invalid_cd, Path.t()}
             | {:invalid_option, term}
             | {:start_error, String.t()}}
  def start_link([cmd | args], opts \\ []) when is_binary(cmd) do
    with {:ok, path} <- find_executable(cmd),
         {:ok, cd} <- normalize_cd(opts[:cd]),
         {:ok, stderr} <- normalize_stderr(opts[:stderr]),
         {:ok, env} <- normalize_env(opts[:env]),
         {:ok, log} <- normalize_log(opts[:log]),
         {:ok, oom_score_adj} <- normalize_oom_score_adj(opts[:oom_score_adj]),
         {:ok, memory_limit} <- normalize_memory_limit(opts[:memory_limit]) do
      spec = %{
        cmd: [path | args],
        cd: cd,
        stderr: stderr,
        env: env,
        log: log,
        grace: Keyword.get(opts, :grace, @default_grace_ms),
        oom_score_adj: oom_score_adj,
        memory_limit: memory_limit,
        caller: self()
      }

      case GenServer.start_link(__MODULE__, spec) do
        {:ok, pid} ->
          {:ok, pid}

        :ignore ->
          receive do
            {__MODULE__, :start_error, reason} -> {:error, {:start_error, reason}}
          after
            0 -> {:error, {:start_error, "shim did not start"}}
          end
      end
    end
  end

  @doc """
  Runs a command to completion, collecting stdout and stderr separately.
  Both streams are drained concurrently so a chatty child never deadlocks.
  Options as `start_link/2`, plus `:input` (written then stdin closed) and
  `:timeout` (kills the process tree; default 60 s).
  """
  @spec run([String.t(), ...], keyword) ::
          {:ok, %{status: integer, stdout: binary, stderr: binary}} | {:error, term}
  def run(cmd_with_args, opts \\ []) do
    {input, opts} = Keyword.pop(opts, :input)
    {timeout, opts} = Keyword.pop(opts, :timeout, 60_000)

    with {:ok, shim} <- start_link(cmd_with_args, opts) do
      stdout = Task.async(fn -> drain(shim, &read/3) end)
      stderr = Task.async(fn -> drain(shim, &read_stderr/3) end)

      if input, do: :ok = write(shim, input)
      :ok = close_stdin(shim)

      case await_exit(shim, timeout) do
        {:ok, status} ->
          {:ok,
           %{
             status: status,
             stdout: Task.await(stdout, timeout),
             stderr: Task.await(stderr, timeout)
           }}

        {:error, :timeout} ->
          kill(shim, 1_000)
          await_exit(shim, 5_000)
          Task.shutdown(stdout, :brutal_kill)
          Task.shutdown(stderr, :brutal_kill)
          {:error, :timeout}

        {:error, _} = error ->
          error
      end
    end
  end

  defp drain(shim, reader, acc \\ []) do
    case reader.(shim, Proto.max_chunk(), :infinity) do
      {:ok, data} -> drain(shim, reader, [data | acc])
      _eof_or_closed -> acc |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end

  @doc "Path to the shim binary for this platform."
  @spec executable() :: Path.t()
  def executable do
    Application.app_dir(:longx, ["priv", "bin", Longx.Platform.shim_executable_name()])
  end

  @doc "OS pid of the child. On unix this is also its process group id."
  @spec os_pid(GenServer.server()) :: pos_integer
  def os_pid(shim), do: GenServer.call(shim, :os_pid)

  @doc """
  Process count, resident memory and CPU time of the child's whole process
  tree (Linux: /proc walk by parent pid; Windows: the Job object; macOS:
  `ps`). Zeros once the child has exited.
  """
  @spec stats(GenServer.server(), timeout) :: {:ok, Proto.stats()} | {:error, :closed}
  def stats(shim, timeout \\ 5_000), do: GenServer.call(shim, :stats, timeout)

  @doc """
  Reads at most `max` bytes from stdout, blocking until the child produces
  something. `:eof` once the child closed stdout or after `close_stdout/1`.
  """
  @spec read(GenServer.server(), pos_integer, timeout) :: read_result
  def read(shim, max \\ Proto.max_chunk(), timeout \\ :infinity),
    do: GenServer.call(shim, {:read, :stdout, max}, timeout)

  @doc "Same as `read/3` for stderr. `:eof` immediately unless `stderr: :stream`."
  @spec read_stderr(GenServer.server(), pos_integer, timeout) :: read_result
  def read_stderr(shim, max \\ Proto.max_chunk(), timeout \\ :infinity),
    do: GenServer.call(shim, {:read, :stderr, max}, timeout)

  @doc """
  Writes `data` to the child's stdin, returning once the shim has accepted
  all of it. Blocks while the child is not consuming its input.
  """
  @spec write(GenServer.server(), iodata, timeout) :: :ok | {:error, :closed}
  def write(shim, data, timeout \\ 5_000),
    do: GenServer.call(shim, {:write, IO.iodata_to_binary(data)}, timeout)

  @spec close_stdin(GenServer.server()) :: :ok
  def close_stdin(shim), do: GenServer.call(shim, :close_stdin)

  @spec close_stdout(GenServer.server()) :: :ok
  def close_stdout(shim), do: GenServer.call(shim, {:close_stream, :stdout})

  @spec close_stderr(GenServer.server()) :: :ok
  def close_stderr(shim), do: GenServer.call(shim, {:close_stream, :stderr})

  @doc "Sends a signal (`:hup | :int | :kill | :term` or a number) to the process group."
  @spec signal(GenServer.server(), :hup | :int | :kill | :term | non_neg_integer) :: :ok
  def signal(shim, sig) when is_map_key(@signals, sig), do: signal(shim, @signals[sig])
  def signal(shim, sig) when is_integer(sig), do: GenServer.call(shim, {:signal, sig})

  @doc """
  Terminates the child tree: SIGTERM now, SIGKILL if it is still alive after
  `grace_ms`. Returns immediately; follow with `await_exit/2`.
  """
  @spec kill(GenServer.server(), non_neg_integer) :: :ok
  def kill(shim, grace_ms \\ @default_grace_ms), do: GenServer.call(shim, {:kill, grace_ms})

  @doc """
  Waits for the child to exit and returns its status (`128 + signal` when
  killed by a signal). Closes any stream not yet at eof so the shim can exit,
  after which the server stops with reason `:normal`.
  """
  @spec await_exit(GenServer.server(), timeout) ::
          {:ok, integer} | {:error, :timeout | :shim_exited}
  def await_exit(shim, timeout \\ 5_000) do
    GenServer.call(shim, {:await_exit, timeout}, :infinity)
  end

  ## Server

  @impl true
  def init(spec) do
    # Trap exits: a port dying with :epipe (the child exited while we were
    # still writing, e.g. close_stdin racing a fast command) must be handled
    # like any other shim exit, not kill this server and its owner.
    Process.flag(:trap_exit, true)
    port = open_port(spec)
    Port.command(port, Proto.encode(:env, spec.env))

    receive do
      {^port, {:data, data}} ->
        case Proto.decode(data) do
          {:pid, os_pid} ->
            {:ok, %State{port: port, os_pid: os_pid, owner: spec.caller}}

          {:start_error, reason} ->
            send(spec.caller, {__MODULE__, :start_error, reason})
            :ignore

          other ->
            send(
              spec.caller,
              {__MODULE__, :start_error, "unexpected first packet #{inspect(other)}"}
            )

            :ignore
        end

      {^port, {:exit_status, code}} ->
        send(spec.caller, {__MODULE__, :start_error, "shim exited with status #{code}"})
        :ignore
    after
      @start_timeout ->
        Port.close(port)
        send(spec.caller, {__MODULE__, :start_error, "timed out waiting for the shim"})
        :ignore
    end
  end

  @impl true
  def handle_call(:os_pid, _from, state), do: {:reply, state.os_pid, state}

  def handle_call(:stats, _from, %State{shim_exited?: true} = state),
    do: {:reply, {:error, :closed}, state}

  def handle_call(:stats, from, %State{} = state) do
    if state.stats_waiters == [], do: command(state, Proto.encode(:send_stats))
    {:noreply, %State{state | stats_waiters: [from | state.stats_waiters]}}
  end

  def handle_call({:read, name, max}, from, state) do
    stream = stream(state, name)

    cond do
      stream.status == :eof -> {:reply, :eof, state}
      stream.pending != nil -> {:reply, {:error, :pending_read}, state}
      state.shim_exited? -> {:reply, {:error, :closed}, state}
      true -> {:noreply, request_read(state, name, max, from)}
    end
  end

  def handle_call({:write, _data}, _from, %State{stdin: :closed} = state),
    do: {:reply, {:error, :closed}, state}

  def handle_call({:write, _data}, _from, %State{shim_exited?: true} = state),
    do: {:reply, {:error, :closed}, state}

  def handle_call({:write, data}, from, %State{} = state) do
    state = %State{state | writes: :queue.in({from, data}, state.writes)}
    {:noreply, maybe_send_input(state)}
  end

  def handle_call(:close_stdin, _from, %State{stdin: :closed} = state), do: {:reply, :ok, state}

  def handle_call(:close_stdin, _from, %State{} = state) do
    # Writers still queued will never be accepted.
    state = reply_all_writes(state, {:error, :closed})
    command(state, Proto.encode(:close_input))
    {:reply, :ok, %State{state | stdin: :closed}}
  end

  def handle_call({:close_stream, name}, _from, state) do
    {:reply, :ok, close_stream(state, name)}
  end

  def handle_call({:signal, sig}, _from, state) do
    command(state, Proto.encode(:signal, sig))
    {:reply, :ok, state}
  end

  def handle_call({:kill, grace_ms}, _from, state) do
    command(state, Proto.encode(:kill, grace_ms))
    {:reply, :ok, state}
  end

  def handle_call({:await_exit, timeout}, from, %State{} = state) do
    state = %State{state | awaited?: true}

    case state.exit_status do
      nil when state.shim_exited? ->
        {:reply, {:error, :shim_exited}, state}

      nil ->
        timer =
          if timeout == :infinity,
            do: nil,
            else: Process.send_after(self(), {:await_timeout, from}, timeout)

        {:noreply, %State{state | exit_waiters: [{from, timer} | state.exit_waiters]}}

      status ->
        state = close_remaining_streams(state)
        maybe_stop({:reply, {:ok, status}, state})
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %State{port: port} = state) do
    state = data |> Proto.decode() |> handle_event(state)
    maybe_stop({:noreply, state})
  end

  def handle_info({port, {:exit_status, code}}, %State{port: port} = state) do
    if state.exit_status == nil do
      Logger.warning("shim exited with status #{code} before reporting the child's exit")
    end

    maybe_stop({:noreply, shim_gone(state)})
  end

  # The port itself died (typically :epipe after the child exited). Same as
  # an exit_status we may or may not still receive.
  def handle_info({:EXIT, port, _reason}, %State{port: port, shim_exited?: false} = state),
    do: maybe_stop({:noreply, shim_gone(state)})

  def handle_info({:EXIT, port, _reason}, %State{port: port} = state), do: {:noreply, state}

  # The owner died: we are linked on purpose so the child does not outlive it.
  def handle_info({:EXIT, owner, reason}, %State{owner: owner} = state),
    do: {:stop, reason, state}

  def handle_info({:await_timeout, from}, %State{} = state) do
    case List.keytake(state.exit_waiters, from, 0) do
      {{^from, _timer}, rest} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %State{state | exit_waiters: rest}}

      nil ->
        {:noreply, state}
    end
  end

  defp shim_gone(%State{} = state) do
    Enum.each(state.stats_waiters, &GenServer.reply(&1, {:error, :closed}))

    state =
      %State{state | shim_exited?: true, stats_waiters: []}
      |> reply_all_writes({:error, :closed})
      |> reply_pending_read(
        :stdout,
        if(state.stdout.status == :eof, do: :eof, else: {:error, :closed})
      )
      |> reply_pending_read(
        :stderr,
        if(state.stderr.status == :eof, do: :eof, else: {:error, :closed})
      )
      |> reply_exit_waiters(
        if(state.exit_status, do: {:ok, state.exit_status}, else: {:error, :shim_exited})
      )

    state
  end

  @impl true
  def terminate(_reason, %State{port: port, shim_exited?: false}) do
    # Closing our side of the pipe is the shim's signal to take the child down.
    if Port.info(port), do: Port.close(port)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  ## Events from the shim

  defp handle_event({:output, data}, state), do: reply_pending_read(state, :stdout, {:ok, data})
  defp handle_event({:stderr, data}, state), do: reply_pending_read(state, :stderr, {:ok, data})
  defp handle_event(:output_eof, state), do: mark_eof(state, :stdout)
  defp handle_event(:stderr_eof, state), do: mark_eof(state, :stderr)

  defp handle_event({:stats, stats}, %State{} = state) do
    Enum.each(state.stats_waiters, &GenServer.reply(&1, {:ok, stats}))
    %State{state | stats_waiters: []}
  end

  defp handle_event(:send_input, %State{} = state),
    do: maybe_send_input(%State{state | credit: true})

  defp handle_event({:exit_status, status}, %State{} = state) do
    state = %State{state | exit_status: status} |> reply_exit_waiters({:ok, status})
    if state.awaited?, do: close_remaining_streams(state), else: state
  end

  defp handle_event(event, state) do
    Logger.warning("unexpected packet from shim: #{inspect(event)}")
    state
  end

  ## Helpers

  defp request_read(state, name, max, from) do
    tag = if name == :stdout, do: :send_output, else: :send_stderr
    command(state, Proto.encode(tag, min(max, Proto.max_chunk())))
    %Stream{} = stream = stream(state, name)
    put_stream(state, name, %Stream{stream | pending: from})
  end

  defp reply_pending_read(state, name, reply) do
    case stream(state, name) do
      %Stream{pending: nil} ->
        state

      %Stream{pending: from} = stream ->
        GenServer.reply(from, reply)
        put_stream(state, name, %Stream{stream | pending: nil})
    end
  end

  defp mark_eof(state, name) do
    %Stream{} = stream = stream(state, name)
    state = put_stream(state, name, %Stream{stream | status: :eof})
    reply_pending_read(state, name, :eof)
  end

  defp close_stream(state, name) do
    case stream(state, name) do
      %Stream{status: :open} = stream ->
        tag = if name == :stdout, do: :close_output, else: :close_stderr
        command(state, Proto.encode(tag))
        # the shim answers with the eof marker, which also resolves any pending read
        put_stream(state, name, %Stream{stream | status: :closing})

      _ ->
        state
    end
  end

  defp close_remaining_streams(state) do
    state |> close_stream(:stdout) |> close_stream(:stderr)
  end

  defp stream(%State{stdout: stream}, :stdout), do: stream
  defp stream(%State{stderr: stream}, :stderr), do: stream

  defp put_stream(%State{} = state, :stdout, stream), do: %State{state | stdout: stream}
  defp put_stream(%State{} = state, :stderr, stream), do: %State{state | stderr: stream}

  # One Input packet per SendInput credit; a write is answered once its last
  # chunk has been handed over.
  defp maybe_send_input(%State{credit: false} = state), do: state

  defp maybe_send_input(%State{credit: true} = state) do
    case :queue.out(state.writes) do
      {:empty, _} ->
        state

      {{:value, {from, data}}, rest} ->
        {chunk, remaining} = split_chunk(data)
        command(state, Proto.encode(:input, chunk))

        writes =
          if remaining == <<>> do
            GenServer.reply(from, :ok)
            rest
          else
            :queue.in_r({from, remaining}, rest)
          end

        %State{state | credit: false, writes: writes}
    end
  end

  defp split_chunk(data) do
    max = Proto.max_chunk()

    case data do
      <<chunk::binary-size(max), rest::binary>> when rest != <<>> -> {chunk, rest}
      whole -> {whole, <<>>}
    end
  end

  defp reply_all_writes(%State{} = state, reply) do
    state.writes
    |> :queue.to_list()
    |> Enum.each(fn {from, _} -> GenServer.reply(from, reply) end)

    %State{state | writes: :queue.new()}
  end

  defp reply_exit_waiters(%State{} = state, reply) do
    Enum.each(state.exit_waiters, fn {from, timer} ->
      if timer, do: Process.cancel_timer(timer)
      GenServer.reply(from, reply)
    end)

    %State{state | exit_waiters: []}
  end

  # Once the shim is gone and someone has collected the exit status there is
  # nothing left to serve.
  defp maybe_stop({:noreply, %State{shim_exited?: true, awaited?: true} = state}),
    do: {:stop, :normal, state}

  defp maybe_stop({:reply, reply, %State{shim_exited?: true, awaited?: true} = state}),
    do: {:stop, :normal, reply, state}

  defp maybe_stop(other), do: other

  defp command(%State{port: port}, payload) do
    Port.command(port, payload)
  rescue
    ArgumentError ->
      if Port.info(port),
        do: reraise(ArgumentError, "port command failed", __STACKTRACE__),
        else: false
  end

  defp open_port(spec) do
    args =
      [
        "-protocol_version",
        Proto.version(),
        "-stderr",
        Atom.to_string(spec.stderr),
        "-grace",
        "#{spec.grace}ms"
      ] ++
        if(spec.cd, do: ["-cd", spec.cd], else: []) ++
        if(spec.log, do: ["-log", spec.log], else: []) ++
        if(spec.oom_score_adj, do: ["-oom_score_adj", "#{spec.oom_score_adj}"], else: []) ++
        if(spec.memory_limit, do: ["-memory_limit", "#{spec.memory_limit}"], else: []) ++
        ["--" | spec.cmd]

    Port.open({:spawn_executable, executable()}, [
      :binary,
      :exit_status,
      :use_stdio,
      :hide,
      {:packet, 4},
      {:args, args}
    ])
  end

  ## Option normalisation

  defp find_executable(cmd) do
    case System.find_executable(cmd) do
      nil -> {:error, {:command_not_found, cmd}}
      path -> {:ok, path}
    end
  end

  defp normalize_oom_score_adj(nil), do: {:ok, nil}
  defp normalize_oom_score_adj(0), do: {:ok, nil}
  defp normalize_oom_score_adj(n) when is_integer(n) and n in -1000..1000, do: {:ok, n}
  defp normalize_oom_score_adj(n), do: {:error, {:invalid_option, {:oom_score_adj, n}}}

  defp normalize_memory_limit(nil), do: {:ok, nil}
  defp normalize_memory_limit(n) when is_integer(n) and n > 0, do: {:ok, n}
  defp normalize_memory_limit(n), do: {:error, {:invalid_option, {:memory_limit, n}}}

  defp normalize_cd(nil), do: {:ok, nil}

  defp normalize_cd(cd) when is_binary(cd) do
    if File.dir?(cd), do: {:ok, Path.expand(cd)}, else: {:error, {:invalid_cd, cd}}
  end

  defp normalize_cd(cd), do: {:error, {:invalid_option, {:cd, cd}}}

  defp normalize_stderr(nil), do: {:ok, :stream}

  defp normalize_stderr(mode) when mode in [:stream, :console, :disable, :redirect_to_stdout],
    do: {:ok, mode}

  defp normalize_stderr(mode), do: {:error, {:invalid_option, {:stderr, mode}}}

  defp normalize_env(nil), do: {:ok, []}

  defp normalize_env(env) when is_list(env) or is_map(env) do
    {:ok, Enum.map(env, fn {k, v} -> {to_string(k), to_string(v)} end)}
  end

  defp normalize_env(env), do: {:error, {:invalid_option, {:env, env}}}

  defp normalize_log(nil), do: {:ok, nil}
  defp normalize_log(:stderr), do: {:ok, "stderr"}
  defp normalize_log(path) when is_binary(path), do: {:ok, path}
  defp normalize_log(log), do: {:error, {:invalid_option, {:log, log}}}
end
