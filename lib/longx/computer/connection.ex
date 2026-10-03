defmodule Longx.Computer.Connection do
  @moduledoc """
  One connection process per computer and one controller per desktop. HTTP work runs in
  monitored tasks, not the kernel or this server. Killing a tool closes the
  transport and invalidates the observation; unknown actions are never replayed.
  """
  use GenServer

  alias Longx.Computer.{MCP, Service}

  @tools ~w(list_apps list_windows launch_app get_window_state get_desktop_state
    verify_state click double_click right_click drag scroll type_text set_value
    press_key hotkey zoom set_window_frame invoke_menu clipboard_read clipboard_write)
  @read_only ~w(list_apps list_windows get_window_state get_desktop_state verify_state zoom clipboard_read)
  @observations ~w(get_window_state get_desktop_state)
  @hidden ~w(session screenshot_out_file debug_image_out _session_id _transport_session_id)

  def start_link(opts \\ []) do
    id = Keyword.get(opts, :id, "local")
    GenServer.start_link(__MODULE__, opts, name: server(id))
  end

  def child_spec(opts),
    do: %{
      id: {__MODULE__, Keyword.get(opts, :id, "local")},
      start: {__MODULE__, :start_link, [opts]}
    }

  defp server("local"), do: __MODULE__
  defp server(id), do: {:via, Registry, {Longx.Computer.Registry, id}}
  def ensure("local"), do: :ok

  def ensure(id) do
    with {:ok, config} <- Service.configuration(),
         true <- Map.has_key?(config["computers"], id) do
      case Registry.lookup(Longx.Computer.Registry, id) do
        [{_, _}] ->
          :ok

        [] ->
          case DynamicSupervisor.start_child(Longx.Computer.Supervisor, {__MODULE__, id: id}) do
            {:ok, _} -> :ok
            {:error, {:already_started, _}} -> :ok
            _ -> {:error, "Could not start computer connection"}
          end
      end
    else
      _ -> {:error, "Unknown computer"}
    end
  end

  def status(id \\ "local") do
    case request(id, :status) do
      {:error, message} ->
        %{
          phase: "disconnected",
          foreground: false,
          busy: false,
          tool_count: 0,
          permissions: nil,
          error: message
        }

      status ->
        status
    end
  end

  def catalog(id \\ "local") do
    case request(id, :catalog) do
      {:error, _} -> []
      catalog -> catalog
    end
  end

  def connect(foreground \\ false), do: connect("local", foreground)

  def connect(id, foreground), do: request(id, {:connect, foreground}, 15_000)

  def disconnect(id \\ "local") do
    case request(id, :disconnect) do
      {:error, _} -> :ok
      result -> result
    end
  end

  def stop("local"), do: disconnect()

  def stop(id) do
    case Registry.lookup(Longx.Computer.Registry, id) do
      [{pid, _}] ->
        GenServer.call(pid, :disconnect)
        DynamicSupervisor.terminate_child(Longx.Computer.Supervisor, pid)

      [] ->
        :ok
    end
  end

  def call(owner, name, args), do: call("local", owner, name, args)

  def call(id, owner, name, args), do: request(id, {:call, owner, name, args}, 40_000)

  def release(owner), do: release("local", owner)
  def release(id, owner), do: GenServer.cast(server(id), {:release, owner})
  def generation(id), do: GenServer.call(server(id), :generation)

  def call(id, owner, name, args, generation),
    do: GenServer.call(server(id), {:pinned_call, generation, owner, name, args}, 40_000)

  def tools, do: @tools

  defp request(id, message, timeout \\ 5_000) do
    with :ok <- ensure(id), do: GenServer.call(server(id), message, timeout)
  end

  @impl true
  def init(opts) do
    Process.send_after(self(), :heartbeat, 15_000)

    {:ok,
     %{
       id: Keyword.get(opts, :id, "local"),
       generation: System.unique_integer([:positive, :monotonic]),
       phase: :disconnected,
       endpoint: nil,
       catalog: [],
       foreground: false,
       permissions: nil,
       error: nil,
       task: nil,
       owner: nil,
       observed: false,
       release: false,
       owner_ref: nil
     }}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, public(state), state}
  def handle_call(:catalog, _from, state), do: {:reply, state.catalog, state}
  def handle_call(:generation, _from, state), do: {:reply, state.generation, state}

  def handle_call({:pinned_call, generation, owner, name, args}, from, state) do
    if generation == state.generation,
      do: handle_call({:call, owner, name, args}, from, state),
      else:
        {:reply,
         {:error, "Computer connection changed; start a new turn and observe before input"},
         state}
  end

  def handle_call({:connect, _}, _from, %{task: task} = state) when not is_nil(task),
    do: {:reply, {:error, "a desktop request is still running"}, state}

  def handle_call({:connect, _}, _from, %{owner: owner} = state) when not is_nil(owner),
    do: {:reply, {:error, "a conversation still controls the desktop"}, state}

  def handle_call({:connect, foreground}, _from, state) do
    server = self()
    close_transport(state)

    state =
      spawn_work(state, nil, :connect, fn ->
        with {:ok, endpoint, tools} <-
               Service.ensure(state.id, fn endpoint ->
                 send(server, {:endpoint, self(), endpoint})
                 :ok
               end),
             {:ok, permissions} <- permissions(endpoint, tools) do
          {:ok, endpoint, tools, permissions}
        end
      end)

    state = %{
      state
      | phase: :connecting,
        foreground: foreground,
        error: nil,
        generation: System.unique_integer([:positive, :monotonic]),
        observed: false
    }

    {:reply, {:ok, public(state)}, state}
  end

  def handle_call(:disconnect, _from, state) do
    state = state |> cancel() |> drop_owner()
    close_transport(state)

    {:reply, :ok,
     %{state | phase: :disconnected, owner: nil, observed: false, catalog: [], release: false}}
  end

  def handle_call({:call, _owner, _name, _args}, _from, %{phase: phase} = state)
      when phase != :ready,
      do: {:reply, {:error, "connect Longx Computer in Settings → Agent kernel first"}, state}

  def handle_call({:call, owner, name, args}, from, state) do
    tool = Enum.find(state.catalog, &(&1["name"] == name))

    takeover =
      args["delivery_mode"] == "foreground" or
        get_in(args, ["target", "kind"]) == "desktop" or args["scope"] == "desktop" or
        name in ~w(get_desktop_state invoke_menu)

    cond do
      state.task != nil or (state.owner != nil and state.owner != owner) ->
        {:reply, {:error, "the desktop is controlled by another call or conversation"}, state}

      tool == nil ->
        {:reply, {:error, "this Driver does not expose that computer tool"}, state}

      takeover and not state.foreground ->
        {:reply,
         {:error,
          "visible foreground/full-desktop control is not enabled; ask the person to enable it in Settings"},
         state}

      name not in @read_only and name != "launch_app" and not state.observed ->
        {:reply, {:error, "observe the target with computer_get_window_state before input"},
         state}

      true ->
        endpoint = state.endpoint
        first = state.owner == nil
        session = session(owner)
        args = Map.drop(args, @hidden)

        args =
          if get_in(tool, ["inputSchema", "properties", "session"]),
            do: Map.put(args, "session", session),
            else: args

        state = acquire(state, owner)

        state =
          spawn_work(state, from, {:call, name}, fn ->
            with {:ok, _} <- MCP.request(endpoint, "ping"),
                 :ok <- begin_session(endpoint, session, first),
                 {:ok, result} <- MCP.call(endpoint, name, args) do
              {:ok, result}
            else
              error -> error
            end
          end)

        {:noreply, %{state | owner: owner}}
    end
  end

  @impl true
  def handle_cast({:release, owner}, %{owner: owner, task: nil} = state),
    do: {:noreply, cleanup(state)}

  def handle_cast({:release, owner}, %{owner: owner} = state),
    do: {:noreply, %{state | release: true}}

  def handle_cast(_, state), do: {:noreply, state}

  @impl true
  def handle_info(:heartbeat, state) do
    Process.send_after(self(), :heartbeat, 15_000)

    if state.phase == :ready and state.task == nil do
      endpoint = state.endpoint
      {:noreply, spawn_work(state, nil, :heartbeat, fn -> MCP.request(endpoint, "ping") end)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:endpoint, pid, endpoint}, %{task: %{worker: %Task{pid: pid}}} = state),
    do: {:noreply, %{state | endpoint: endpoint}}

  def handle_info(
        {:thread, _seq, "turn/completed", %{"threadId" => thread, "turn" => %{"id" => turn}}},
        %{owner: {thread, turn}, task: nil} = state
      ),
      do: {:noreply, cleanup(state)}

  def handle_info(
        {:thread, _seq, "turn/completed", %{"threadId" => thread, "turn" => %{"id" => turn}}},
        %{owner: {thread, turn}, task: %{kind: :cleanup}} = state
      ),
      do: {:noreply, state}

  def handle_info(
        {:thread, _seq, "turn/completed", %{"threadId" => thread, "turn" => %{"id" => turn}}},
        %{owner: {thread, turn}} = state
      ) do
    state = state |> cancel() |> drop_owner()
    close_transport(state)

    {:noreply,
     %{
       state
       | phase: :disconnected,
         catalog: [],
         error: "The turn ended during input; reconnect and observe before continuing."
     }}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{owner_ref: ref, task: nil} = state),
    do: {:noreply, cleanup(state)}

  def handle_info({:DOWN, ref, :process, _, _}, %{owner_ref: ref} = state) do
    state = state |> cancel() |> drop_owner()
    close_transport(state)

    {:noreply,
     %{
       state
       | phase: :disconnected,
         catalog: [],
         error: "The controlling agent exited; input may have happened. Reconnect and observe."
     }}
  end

  def handle_info({ref, result}, %{task: %{worker: %Task{ref: ref}} = work} = state) do
    Process.cancel_timer(work.timer)
    Process.demonitor(ref, [:flush])
    Process.demonitor(work.caller_ref, [:flush])
    state = %{state | task: nil}
    {reply, state} = finish(work.kind, result, state)
    if work.from, do: GenServer.reply(work.from, reply)
    state = if state.release, do: cleanup(state), else: state
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{task: %{caller_ref: ref}} = state) do
    state = state |> cancel() |> drop_owner()
    close_transport(state)

    {:noreply,
     %{
       state
       | phase: :disconnected,
         catalog: [],
         owner: nil,
         observed: false,
         error:
           "The request was interrupted; input may have happened. Reconnect and observe before continuing."
     }}
  end

  def handle_info(
        {:DOWN, ref, :process, _, _},
        %{task: %{worker: %Task{ref: ref}} = work} = state
      ) do
    Process.cancel_timer(work.timer)
    Process.demonitor(work.caller_ref, [:flush])
    state = drop_owner(state)

    if work.from,
      do:
        GenServer.reply(
          work.from,
          {:error, "the desktop request ended unexpectedly; do not replay it"}
        )

    close_transport(state)

    {:noreply,
     %{
       state
       | task: nil,
         owner: nil,
         observed: false,
         phase: :disconnected,
         catalog: [],
         error: "The desktop connection was lost; reconnect and observe."
     }}
  end

  def handle_info({:work_timeout, ref}, %{task: %{worker: %Task{ref: ref}}} = state) do
    state = state |> cancel() |> drop_owner()
    close_transport(state)

    {:noreply,
     %{
       state
       | phase: :disconnected,
         catalog: [],
         owner: nil,
         observed: false,
         error: "The desktop request timed out; input may have happened. Reconnect and observe."
     }}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    cancel(state)
    close_transport(state)
  end

  defp spawn_work(state, from, kind, fun) do
    caller = if from, do: elem(from, 0), else: self()
    worker = Task.Supervisor.async_nolink(Longx.Computer.TaskSupervisor, fun)
    timeout = if kind == :connect, do: 12_000, else: 35_000
    timer = Process.send_after(self(), {:work_timeout, worker.ref}, timeout)

    %{
      state
      | task: %{
          worker: worker,
          from: from,
          caller_ref: Process.monitor(caller),
          kind: kind,
          timer: timer
        }
    }
  end

  defp finish(:connect, {:ok, endpoint, tools, permissions}, state) do
    tools = Enum.filter(tools, &(&1["name"] in @tools))

    state = %{
      state
      | phase: :ready,
        endpoint: endpoint,
        catalog: tools,
        permissions: permissions,
        owner: nil,
        observed: false,
        error: nil
    }

    {{:ok, public(state)}, state}
  end

  defp finish(:connect, {:error, reason}, state) do
    close_transport(state)
    message = describe(reason)
    {{:error, message}, %{state | phase: :disconnected, catalog: [], error: message}}
  end

  defp finish({:call, name}, {:ok, result}, state) do
    observed = state.observed or (name in @observations and result["isError"] != true)
    {{:ok, result}, %{state | observed: observed}}
  end

  defp finish({:call, _}, {:error, reason}, state) do
    close_transport(state)
    message = describe(reason)
    state = drop_owner(state)

    {{:error, message},
     %{state | phase: :disconnected, catalog: [], owner: nil, observed: false, error: message}}
  end

  defp finish(:heartbeat, {:ok, _}, state), do: {:ok, state}

  defp finish(:heartbeat, {:error, reason}, state),
    do: finish({:call, "ping"}, {:error, reason}, state)

  defp finish(:cleanup, {:ok, %{"isError" => true}}, state),
    do: finish(:cleanup, {:error, :session_refused}, state)

  defp finish(:cleanup, {:error, _}, state) do
    close_transport(state)
    state = drop_owner(state)

    {:ok,
     %{
       state
       | phase: :disconnected,
         catalog: [],
         owner: nil,
         observed: false,
         release: false,
         error: "The desktop session could not be cleaned up; reconnect before continuing."
     }}
  end

  defp finish(:cleanup, _result, state),
    do: {:ok, %{drop_owner(state) | release: false}}

  defp acquire(%{owner: nil} = state, {thread, _turn} = owner) do
    Phoenix.PubSub.subscribe(Longx.PubSub, "thread:#{thread}")
    pid = Longx.Agent.whereis(thread)
    %{state | owner: owner, owner_ref: if(pid, do: Process.monitor(pid))}
  end

  defp acquire(state, _owner), do: state

  defp drop_owner(%{owner: nil} = state), do: state

  defp drop_owner(%{owner: {thread, _}} = state) do
    Phoenix.PubSub.unsubscribe(Longx.PubSub, "thread:#{thread}")
    if state.owner_ref, do: Process.demonitor(state.owner_ref, [:flush])
    %{state | owner: nil, owner_ref: nil, observed: false}
  end

  defp cleanup(%{owner: nil} = state), do: %{state | release: false}

  defp cleanup(state) do
    endpoint = state.endpoint
    session = session(state.owner)

    spawn_work(%{state | release: false}, nil, :cleanup, fn ->
      MCP.call(endpoint, "end_session", %{"session" => session})
    end)
  end

  defp cancel(%{task: nil} = state), do: state

  defp cancel(%{task: work} = state) do
    Process.cancel_timer(work.timer)
    Task.shutdown(work.worker, :brutal_kill)
    Process.demonitor(work.caller_ref, [:flush])

    if work.from,
      do:
        GenServer.reply(
          work.from,
          {:error, "desktop request interrupted; input may have happened"}
        )

    %{state | task: nil}
  end

  defp close_transport(%{endpoint: %{url: url} = endpoint}) do
    MCP.close(endpoint)
    Finch.stop_pool(Longx.Computer.Finch, url)
  end

  defp close_transport(_), do: :ok
  defp session({thread, turn}), do: "longx-#{thread}-#{turn}"

  defp begin_session(_endpoint, _session, false), do: :ok

  defp begin_session(endpoint, session, true) do
    case MCP.call(endpoint, "start_session", %{"session" => session}) do
      {:ok, %{"isError" => true}} -> {:error, :session_refused}
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp permissions(endpoint, tools) do
    if Enum.any?(tools, &(&1["name"] == "check_permissions")) do
      case MCP.call(endpoint, "check_permissions", %{"prompt" => false}) do
        {:ok, result} ->
          data = result["structuredContent"] || %{}
          {:ok, Map.take(data, ~w(accessibility screen_recording source direct_capture_status))}

        error ->
          error
      end
    else
      {:ok, %{}}
    end
  end

  defp public(state),
    do: %{
      phase: Atom.to_string(state.phase),
      foreground: state.foreground,
      busy: (state.task != nil and state.task.kind != :heartbeat) or state.owner != nil,
      tool_count: length(state.catalog),
      permissions: state.permissions && Jason.encode!(state.permissions),
      error: state.error
    }

  defp describe(:not_configured),
    do: "Save the Longx Computer service URL and access key in Settings first."

  defp describe(:missing_session),
    do:
      "The endpoint did not provide a session. Use the Longx Computer app, not the raw Driver endpoint."

  defp describe(:session_refused),
    do:
      "The computer service refused the desktop lease; another conversation may be controlling it."

  defp describe(:transport_lost),
    do:
      "The connection was lost. Input may have happened; do not replay it. Reconnect and observe."

  defp describe({:http, 404}),
    do:
      "The computer session expired or the app restarted. Reconnect and observe; do not replay input."

  defp describe({:http, status}), do: "The computer service returned HTTP #{status}."
  defp describe({:protocol, message}), do: "MCP: " <> message

  defp describe(_),
    do: "Could not connect to Longx Computer. Check the service URL, access key and desktop app."
end
