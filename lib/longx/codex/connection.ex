defmodule Longx.Codex.Connection do
  @moduledoc """
  The JSON-RPC connection to one `codex-app-server` process.

  Owns a `Longx.Shim` running the bundled binary (with the environment from
  `Longx.Codex.Home.prepare/1`), performs the `initialize` → `initialized`
  handshake, pairs our requests with their responses, answers the requests
  the server sends *us* through a `Longx.Codex.ServerRequest` handler, and
  hands every notification to the thread's `Longx.Codex.ThreadState` (or to
  the `"codex:server"` topic when it carries no `threadId`).

  One connection per codex process; `Longx.Codex.Pool` runs one per project.
  A connection carries a `tag:` (the project id) that goes on its
  broadcasts, and registers every thread it hosts in `Longx.Codex.Registry`
  (`{:thread, id}`) so `Longx.Codex.Thread` can find the connection for a
  thread without being told.

  Topics:
    * `"codex:connection"` — `{:codex_connection, tag, :ready | :down}`
    * `"codex:server"` — `{:codex, method, params}` for thread-less notifications
    * `"codex:thread:<id>"` — see `Longx.Codex.ThreadState`
  """

  use GenServer

  alias Longx.Codex.{Framing, Home, Message, Runtime, ThreadState}
  alias Longx.Shim
  alias Phoenix.PubSub

  require Logger

  @pubsub Longx.PubSub
  @task_supervisor Longx.Codex.TaskSupervisor
  @default_request_timeout :timer.seconds(60)
  @handshake_timeout :timer.seconds(30)

  # Notifications we never want: realtime audio, fuzzy file search UI,
  # Windows sandbox chatter. Everything else flows.
  @opt_out_notifications ~w(
    thread/realtime/started thread/realtime/closed thread/realtime/error thread/realtime/sdp
    thread/realtime/itemAdded thread/realtime/item/started thread/realtime/item/completed
    thread/realtime/item/transcript/delta thread/realtime/outputAudio/delta
    thread/realtime/transcript/delta thread/realtime/transcript/done
    fuzzyFileSearch/sessionUpdated fuzzyFileSearch/sessionCompleted
    windows/worldWritableWarning windowsSandbox/setupCompleted
  )

  @type option ::
          {:name, GenServer.name() | nil}
          | {:tag, term}
          | {:home_dir, Path.t()}
          | {:home, keyword}
          | {:shim, keyword}
          | {:command, [String.t(), ...]}
          | {:env, [{String.t(), String.t()}]}
          | {:cd, Path.t()}
          | {:server_request_handler, module}
          | {:request_timeout, timeout}
          | {:client_info, map}

  @registry Longx.Codex.Registry

  defmodule State do
    @moduledoc false
    defstruct [
      :shim,
      :reader,
      :handler,
      :request_timeout,
      :client_info,
      :tag,
      :started_at,
      :memory_limit,
      threads: MapSet.new(),
      turns: 0,
      active_turns: MapSet.new(),
      phase: :handshaking,
      next_id: 1,
      pending: %{},
      inbound: %{},
      async: %{},
      queue: :queue.new()
    ]
  end

  ## Client

  @doc """
  Starts the connection. Without `:command`/`:env` it launches the bundled
  app-server with our own `CODEX_HOME` (`Home.prepare/1`, in `:home_dir`
  when given). `:tag` (a project id) marks its broadcasts.
  """
  @spec start_link([option]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, nil)

    if name,
      do: GenServer.start_link(__MODULE__, opts, name: name),
      else: GenServer.start_link(__MODULE__, opts)
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [Keyword.delete(opts, :id)]},
      restart: :permanent,
      shutdown: 15_000
    }
  end

  @doc "Sends a request and waits for the response. Queued until the handshake is done."
  @spec request(GenServer.server(), String.t(), term, keyword) ::
          {:ok, term} | {:error, Longx.Codex.Error.t() | :timeout | :connection_reset}
  def request(conn, method, params, opts \\ []) do
    timeout = Keyword.get(opts, :timeout)
    GenServer.call(conn, {:request, method, params, timeout}, :infinity)
  end

  @spec notify(GenServer.server(), String.t(), term) :: :ok
  def notify(conn, method, params), do: GenServer.call(conn, {:notify, method, params})

  @doc "Answers a deferred server → client request (an approval, a question…)."
  @spec respond(GenServer.server(), term, map) :: :ok | {:error, :unknown_request}
  def respond(conn, request_id, result),
    do: GenServer.call(conn, {:respond, request_id, {:reply, result}})

  @spec reject(GenServer.server(), term, integer, String.t()) :: :ok | {:error, :unknown_request}
  def reject(conn, request_id, code, message),
    do: GenServer.call(conn, {:respond, request_id, {:error, code, message}})

  @spec status(GenServer.server()) :: :handshaking | :ready
  def status(conn), do: GenServer.call(conn, :status)

  @doc "Phase, tag, OS pid of the app-server, start time, hosted thread ids."
  @spec info(GenServer.server()) :: map
  def info(conn), do: GenServer.call(conn, :info)

  ## Server

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    conn = self()

    # `shim:` — resource guards (oom_score_adj, memory_limit) for the codex tree
    shim_opts = Keyword.get(opts, :shim, [])

    with {:ok, command, env, cd} <- launch_spec(opts),
         {:ok, shim} <-
           Shim.start_link(command, [env: env, cd: cd, stderr: :console] ++ shim_opts) do
      state = %State{
        shim: shim,
        reader: spawn_link(fn -> __MODULE__.read_loop(shim, conn, "") end),
        tag: Keyword.get(opts, :tag),
        started_at: DateTime.utc_now(),
        memory_limit: Keyword.get(shim_opts, :memory_limit),
        handler: Keyword.get(opts, :server_request_handler, configured_handler()),
        request_timeout: Keyword.get(opts, :request_timeout, @default_request_timeout),
        client_info:
          Keyword.get(opts, :client_info, %{name: "longx", title: "Longx", version: version()})
      }

      {:ok, state, {:continue, :handshake}}
    else
      {:error, :not_installed} ->
        Logger.error(
          "codex-app-server is not installed; run `mix codex.fetch`. Codex features are disabled."
        )

        :ignore

      {:error, reason} ->
        {:stop, {:codex_launch_failed, reason}}
    end
  end

  defp launch_spec(opts) do
    case Keyword.fetch(opts, :command) do
      {:ok, command} ->
        {:ok, command, Keyword.get(opts, :env, []), Keyword.get(opts, :cd)}

      :error ->
        # `home_dir:` places the CODEX_HOME; `home:` are further Home.prepare/1 options
        home_opts =
          opts
          |> Keyword.get(:home, [])
          |> Keyword.merge(Enum.map(Keyword.take(opts, [:home_dir]), fn {_, d} -> {:dir, d} end))

        with {:ok, exe} <- Runtime.executable(),
             {:ok, home} <- Home.prepare(home_opts) do
          {:ok, [exe], home.env, home.dir}
        end
    end
  end

  @impl true
  def handle_continue(:handshake, state) do
    params = %{
      clientInfo: state.client_info,
      # experimentalApi: `thread/start.dynamicTools` (our Elixir tools) is an experimental field
      capabilities: %{experimentalApi: true, optOutNotificationMethods: @opt_out_notifications}
    }

    {:noreply, send_request(state, "initialize", params, :handshake, @handshake_timeout)}
  end

  @impl true
  def handle_call({:request, method, params, timeout}, from, %State{phase: :ready} = state) do
    {:noreply, send_request(state, method, params, from, timeout || state.request_timeout)}
  end

  def handle_call({:request, method, params, timeout}, from, %State{phase: :handshaking} = state) do
    {:noreply, %State{state | queue: :queue.in({from, method, params, timeout}, state.queue)}}
  end

  def handle_call({:notify, method, params}, _from, state) do
    write(state, Message.notification(method, params))
    {:reply, :ok, state}
  end

  # codex numbers its requests; a client that carried the id through JSON /
  # a form may hand it back as a string
  def handle_call({:respond, id, reply}, _from, %State{} = state) do
    id = inbound_id(state.inbound, id)

    case Map.pop(state.inbound, id) do
      {nil, _} ->
        {:reply, {:error, :unknown_request}, state}

      {%{timer: timer, thread_id: thread_id}, inbound} ->
        Process.cancel_timer(timer)
        write_reply(state, id, reply)
        resolve_in_thread(thread_id, id)
        {:reply, :ok, %State{state | inbound: inbound}}
    end
  end

  def handle_call(:status, _from, state), do: {:reply, state.phase, state}

  def handle_call(:info, _from, state) do
    shim_alive? = state.shim && Process.alive?(state.shim)

    info = %{
      pid: self(),
      tag: state.tag,
      phase: state.phase,
      started_at: state.started_at,
      os_pid: shim_alive? && Shim.os_pid(state.shim),
      stats: shim_alive? && tree_stats(state.shim),
      memory_limit: state.memory_limit,
      turns: state.turns,
      active_turns: MapSet.size(state.active_turns),
      threads: MapSet.to_list(state.threads)
    }

    {:reply, info, state}
  end

  @impl true
  def handle_info({:rpc, message}, state) do
    {:noreply, dispatch(Message.classify(message), state)}
  end

  def handle_info({:request_timeout, id}, %State{} = state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        {:noreply, state}

      {%{from: :handshake}, _} ->
        {:stop, {:shutdown, :handshake_timeout}, state}

      {%{from: from}, pending} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %State{state | pending: pending}}
    end
  end

  def handle_info({:inbound_timeout, id}, %State{} = state) do
    case Map.pop(state.inbound, id) do
      {nil, _} ->
        {:noreply, state}

      {%{fallback: fallback, thread_id: thread_id, method: method}, inbound} ->
        Logger.warning("codex request #{method} (#{inspect(id)}) unanswered; sending fallback")
        write_reply(state, id, fallback)
        resolve_in_thread(thread_id, id)
        {:noreply, %State{state | inbound: inbound}}
    end
  end

  # {:async, ...} outcomes: the task's reply, its crash, or our timeout
  def handle_info({ref, result}, %State{async: async} = state) when is_map_key(async, ref) do
    Process.demonitor(ref, [:flush])
    {%{id: id, timer: timer, fallback: fallback, method: method}, async} = Map.pop(async, ref)
    Process.cancel_timer(timer)

    case result do
      {:reply, _} = reply ->
        write_reply(state, id, reply)

      {:error, _, _} = reply ->
        write_reply(state, id, reply)

      other ->
        Logger.warning(
          "codex async handler for #{method} returned #{inspect(other)}; sending fallback"
        )

        write_reply(state, id, fallback)
    end

    {:noreply, %State{state | async: async}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %State{async: async} = state)
      when is_map_key(async, ref) do
    {%{id: id, timer: timer, fallback: fallback, method: method}, async} = Map.pop(async, ref)
    Process.cancel_timer(timer)

    Logger.warning(
      "codex async handler for #{method} crashed: #{inspect(reason)}; sending fallback"
    )

    write_reply(state, id, fallback)
    {:noreply, %State{state | async: async}}
  end

  def handle_info({:async_timeout, ref}, %State{async: async} = state) do
    case Map.pop(async, ref) do
      {nil, _} ->
        {:noreply, state}

      {%{id: id, fallback: fallback, method: method, task: task}, async} ->
        Task.shutdown(task, :brutal_kill)
        Logger.warning("codex async handler for #{method} timed out; sending fallback")
        write_reply(state, id, fallback)
        {:noreply, %State{state | async: async}}
    end
  end

  def handle_info(:reader_eof, state), do: {:stop, {:shutdown, :codex_exited}, state}

  def handle_info({:EXIT, pid, reason}, %State{shim: pid} = state) do
    Logger.error("codex-app-server shim exited: #{inspect(reason)}")
    {:stop, {:shutdown, :codex_exited}, %State{state | shim: nil}}
  end

  def handle_info({:EXIT, pid, reason}, %State{reader: pid} = state) do
    Logger.error("codex reader exited: #{inspect(reason)}")
    {:stop, {:shutdown, :codex_exited}, state}
  end

  def handle_info(other, state) do
    Logger.debug("codex connection ignoring #{inspect(other)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # stop being findable first: shutting the shim down below can take a
    # while, and nobody should be handed a connection that is on its way out
    disown(state)
    fail_pending(state, {:error, :connection_reset})
    withdraw_inbound(state)
    PubSub.broadcast(@pubsub, "codex:connection", {:codex_connection, state.tag, :down})

    if state.shim && Process.alive?(state.shim) do
      Shim.kill(state.shim, 5_000)
      Shim.await_exit(state.shim, 10_000)
    end

    :ok
  end

  ## Dispatch

  defp dispatch({:response, id, result}, %State{} = state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        Logger.debug("codex: late or unknown response #{inspect(id)}")
        state

      {%{timer: timer, from: :handshake}, pending} ->
        Process.cancel_timer(timer)
        finish_handshake(result, %State{state | pending: pending})

      {%{timer: timer, from: from}, pending} ->
        Process.cancel_timer(timer)
        # a thread/start|resume|fork reply names a thread we now host: own it
        # before the caller gets the reply, so a follow-up call finds us
        state = own_thread(%State{state | pending: pending}, thread_id_of_result(result))
        GenServer.reply(from, result)
        state
    end
  end

  defp dispatch({:server_request, id, method, params}, %State{} = state) do
    ctx = %{thread_id: params["threadId"], turn_id: params["turnId"]}

    case state.handler.handle(method, params, ctx) do
      {:defer, timeout, fallback} ->
        timer = Process.send_after(self(), {:inbound_timeout, id}, timeout)

        entry = %{
          method: method,
          params: params,
          fallback: fallback,
          timer: timer,
          thread_id: ctx.thread_id
        }

        if ctx.thread_id, do: put_in_thread(ctx.thread_id, id, method, params)
        %State{state | inbound: Map.put(state.inbound, id, entry)}

      {:async, fun, timeout, fallback} ->
        task = Task.Supervisor.async_nolink(@task_supervisor, fun)
        timer = Process.send_after(self(), {:async_timeout, task.ref}, timeout)
        entry = %{id: id, method: method, fallback: fallback, timer: timer, task: task}
        %State{state | async: Map.put(state.async, task.ref, entry)}

      reply ->
        write_reply(state, id, reply)
        state
    end
  end

  defp dispatch(
         {:notification, "serverRequest/resolved", %{"requestId" => id} = params},
         %State{} = state
       ) do
    # answered elsewhere (another client); drop our pending copy
    case Map.pop(state.inbound, id) do
      {nil, _} ->
        state

      {%{timer: timer, thread_id: thread_id}, inbound} ->
        Process.cancel_timer(timer)
        resolve_in_thread(thread_id, id)
        %State{state | inbound: inbound}
    end
    |> tap(fn _ -> route_notification("serverRequest/resolved", params) end)
  end

  defp dispatch({:notification, method, params}, state) do
    route_notification(method, params)

    state
    |> own_thread(thread_id_of(method, params))
    |> count_turn(method, params)
  end

  defp dispatch({:unknown, message}, state) do
    Logger.warning("codex: unrecognised message #{inspect(message)}")
    state
  end

  # how busy / how used this process is (Longx.Codex.Recycler reads it)
  defp count_turn(%State{} = state, "turn/started", %{"turn" => %{"id" => id}}),
    do: %State{state | turns: state.turns + 1, active_turns: MapSet.put(state.active_turns, id)}

  defp count_turn(%State{} = state, "turn/completed", %{"turn" => %{"id" => id}}),
    do: %State{state | active_turns: MapSet.delete(state.active_turns, id)}

  defp count_turn(state, _method, _params), do: state

  defp tree_stats(shim) do
    case Shim.stats(shim) do
      {:ok, stats} -> stats
      {:error, _} -> nil
    end
  end

  # Every thread this process hosts is registered once, so callers can find
  # the connection by thread id (`Longx.Codex.Pool.connection_for_thread/1`).
  # The registration dies with the process; a restarted codex re-registers
  # threads as it touches them again.
  defp own_thread(state, nil), do: state

  defp own_thread(%State{threads: threads} = state, thread_id) do
    if MapSet.member?(threads, thread_id) do
      state
    else
      Registry.register(@registry, {:thread, thread_id}, state.tag)
      %State{state | threads: MapSet.put(threads, thread_id)}
    end
  end

  defp disown(%State{tag: tag, threads: threads}) do
    if tag, do: Registry.unregister(@registry, {:connection, tag})
    Enum.each(threads, &Registry.unregister(@registry, {:thread, &1}))
  end

  defp thread_id_of_result({:ok, %{"thread" => %{"id" => id}}}) when is_binary(id), do: id
  defp thread_id_of_result(_), do: nil

  defp thread_id_of(_method, %{"threadId" => id}) when is_binary(id), do: id
  defp thread_id_of("thread/started", %{"thread" => %{"id" => id}}) when is_binary(id), do: id
  defp thread_id_of(_method, _params), do: nil

  defp route_notification(method, %{"threadId" => thread_id} = params)
       when is_binary(thread_id),
       do: ingest(thread_id, method, params)

  defp route_notification(
         "thread/started" = method,
         %{"thread" => %{"id" => thread_id}} = params
       ),
       do: ingest(thread_id, method, params)

  defp route_notification(method, params) do
    PubSub.broadcast(@pubsub, "codex:server", {:codex, method, params})
  end

  # the thread's writer being unavailable (its supervisor restarting) loses
  # that one event, never the codex connection
  defp ingest(thread_id, method, params) do
    case ThreadState.ensure(thread_id) do
      {:ok, _} ->
        ThreadState.ingest(thread_id, method, params)

      {:error, reason} ->
        Logger.error("codex connection: dropping #{method} for #{thread_id}: #{inspect(reason)}")
    end
  end

  defp put_in_thread(thread_id, id, method, params) do
    {:ok, _} = ThreadState.ensure(thread_id)
    ThreadState.put_request(thread_id, id, method, params)
  end

  defp inbound_id(inbound, id) when is_binary(id) and not is_map_key(inbound, id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> id
    end
  end

  defp inbound_id(_inbound, id), do: id

  defp resolve_in_thread(nil, _id), do: :ok

  defp resolve_in_thread(thread_id, id) do
    if ThreadState.whereis(thread_id), do: ThreadState.resolve_request(thread_id, id), else: :ok
  end

  ## Handshake

  defp finish_handshake({:ok, _result}, %State{} = state) do
    write(state, Message.notification("initialized", %{}))
    PubSub.broadcast(@pubsub, "codex:connection", {:codex_connection, state.tag, :ready})
    flush_queue(%State{state | phase: :ready})
  end

  defp finish_handshake({:error, error}, state) do
    Logger.error("codex initialize failed: #{Exception.message(error)}")
    fail_pending(state, {:error, :connection_reset})
    exit({:shutdown, {:handshake_failed, error}})
  end

  defp flush_queue(%State{queue: queue} = state) do
    queue
    |> :queue.to_list()
    |> Enum.reduce(%State{state | queue: :queue.new()}, fn {from, method, params, timeout},
                                                           state ->
      send_request(state, method, params, from, timeout || state.request_timeout)
    end)
  end

  ## Wire

  defp send_request(%State{next_id: id} = state, method, params, from, timeout) do
    write(state, Message.request(id, method, params))
    timer = Process.send_after(self(), {:request_timeout, id}, timeout)

    %State{
      state
      | next_id: id + 1,
        pending: Map.put(state.pending, id, %{from: from, method: method, timer: timer})
    }
  end

  defp write_reply(state, id, {:reply, result}), do: write(state, Message.response(id, result))

  defp write_reply(state, id, {:error, code, message}),
    do: write(state, Message.error_response(id, code, message))

  defp write(%State{shim: shim}, message) do
    case Shim.write(shim, Message.encode(message)) do
      :ok -> :ok
      {:error, reason} -> Logger.error("codex write failed: #{inspect(reason)}")
    end
  end

  defp fail_pending(%State{pending: pending, queue: queue}, reply) do
    for {_id, %{from: from, timer: timer}} <- pending, from != :handshake do
      Process.cancel_timer(timer)
      GenServer.reply(from, reply)
    end

    for {from, _m, _p, _t} <- :queue.to_list(queue), do: GenServer.reply(from, reply)
    :ok
  end

  # the approvals / questions this codex was waiting on: nobody can answer
  # them any more, so they leave the threads' views (a resumed thread gets
  # fresh ones from the new process if codex asks again)
  defp withdraw_inbound(%State{inbound: inbound}) do
    for {id, %{timer: timer, thread_id: thread_id}} <- inbound do
      Process.cancel_timer(timer)
      resolve_in_thread(thread_id, id)
    end

    :ok
  end

  # Runs in its own process: Shim.read/3 blocks. Public and recursing through
  # a fully-qualified call so the loop moves to new code on a hot reload —
  # a process lingering in purged code is killed, and that took codex down
  # with every second recompile in dev (`Phoenix.CodeReloader`).
  @doc false
  def read_loop(shim, conn, buffer) do
    case Shim.read(shim) do
      {:ok, chunk} ->
        {lines, buffer} = Framing.split(buffer, chunk)

        Enum.each(lines, fn line ->
          case Jason.decode(line) do
            {:ok, message} ->
              send(conn, {:rpc, message})

            # codex prints notices like "SIGTERM received" on stdout; not protocol, not an error
            {:error, _} ->
              Logger.debug("codex: non-JSON line #{inspect(String.slice(line, 0, 200))}")
          end
        end)

        __MODULE__.read_loop(shim, conn, buffer)

      :eof ->
        send(conn, :reader_eof)

      {:error, reason} ->
        Logger.error("codex: read failed: #{inspect(reason)}")
        send(conn, :reader_eof)
    end
  end

  defp configured_handler do
    :longx
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:server_request_handler, Longx.Codex.ServerRequest.Default)
  end

  defp version, do: to_string(Application.spec(:longx, :vsn) || "0.0.0")
end
