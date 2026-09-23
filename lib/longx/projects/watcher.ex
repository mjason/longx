defmodule Longx.Projects.Watcher do
  @moduledoc """
  A project's file watcher — **only while a page has the project open**.

  The project channel subscribes (`subscribe/2`) when a page joins; the
  watcher monitors every subscriber and, once the last one is gone, leaves
  after `grace_ms` (30 s: a page reload does not restart it) — its port
  closes, the shim sees stdin close and exits. No page, no watcher, no cost.

  The watching is the shim's (`shim watch`: fsnotify, the rules of
  `Longx.Projects.FileRules`, a batch of changes per 200 ms). A batch becomes
  broadcasts on the project's topic:

    * `{:files_changed, id, paths}` — the tree and the git status are stale
      (`[]` when the rules changed or the kernel dropped events: refetch all)
    * `{:definition_changed, id}` — something under `.longx/` changed: the
      page rereads the agent description
    * `{:git_changed, id}` — HEAD, the index or a ref moved (`.git` coming or
      going restarts the watcher: the config differs)
    * `{:watch_status, id, %{watching: boolean, error: text | nil}}`

  The watcher is `:temporary`: a crash is not restarted here; each
  subscriber monitors it and subscribes again, which starts a fresh one.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Longx.Projects
  alias Longx.Projects.FileRules

  @registry Longx.Projects.WatcherRegistry
  @supervisor Longx.Projects.WatcherSupervisor

  ## Client

  @doc "Watches the project while `subscriber` lives (a channel process). `{:ok, watcher, status}`."
  @spec subscribe(String.t(), pid) :: {:ok, pid, map} | {:error, term}
  def subscribe(project_id, subscriber \\ self()) do
    with {:ok, pid} <- ensure(project_id) do
      # a first subscriber waits for the walk: the watches are in place when it returns
      case GenServer.call(pid, {:subscribe, subscriber}, 15_000) do
        {:ok, status} -> {:ok, pid, status}
        other -> other
      end
    end
  catch
    :exit, reason -> {:error, reason}
  end

  @spec whereis(String.t()) :: pid | nil
  def whereis(project_id), do: GenServer.whereis(via(project_id))

  @doc "The rules changed (the project's setting): the running watcher restarts its shim."
  @spec reload(String.t()) :: :ok
  def reload(project_id) do
    case whereis(project_id) do
      nil -> :ok
      pid -> GenServer.cast(pid, :reload)
    end
  end

  @doc "The global rules changed: every running watcher reloads."
  @spec reload_all() :: :ok
  def reload_all do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(@supervisor),
        is_pid(pid),
        do: GenServer.cast(pid, :reload)

    :ok
  end

  @spec stop(String.t()) :: :ok
  def stop(project_id) do
    case whereis(project_id) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end
  catch
    :exit, _ -> :ok
  end

  @doc false
  # the shim's OS pid (tests: it exits with the watcher)
  def os_pid(project_id), do: GenServer.call(via(project_id), :os_pid)

  defp ensure(project_id) do
    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, project_id}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  def start_link(project_id),
    do: GenServer.start_link(__MODULE__, project_id, name: via(project_id))

  defp via(project_id), do: {:via, Registry, {@registry, project_id}}

  ## Server

  @impl true
  def init(project_id) do
    state = %{
      id: project_id,
      subscribers: %{},
      port: nil,
      buffer: "",
      status: %{watching: false, error: nil},
      leave: nil
    }

    {:ok, state, {:continue, :open}}
  end

  @impl true
  def handle_continue(:open, state), do: {:noreply, open(state)}

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    ref = Process.monitor(pid)
    if state.leave, do: Process.cancel_timer(state.leave)

    {:reply, {:ok, state.status},
     %{state | subscribers: Map.put(state.subscribers, ref, pid), leave: nil}}
  end

  def handle_call(:os_pid, _from, %{port: port} = state) when is_port(port),
    do: {:reply, Port.info(port, :os_pid) |> elem(1), state}

  def handle_call(:os_pid, _from, state), do: {:reply, nil, state}

  @impl true
  def handle_cast(:reload, state), do: {:noreply, restart(state)}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    subscribers = Map.delete(state.subscribers, ref)
    state = %{state | subscribers: subscribers}

    if map_size(subscribers) == 0,
      do: {:noreply, %{state | leave: Process.send_after(self(), :leave, grace_ms())}},
      else: {:noreply, state}
  end

  def handle_info(:leave, %{subscribers: subscribers} = state) when map_size(subscribers) == 0,
    do: {:stop, :normal, state}

  def handle_info(:leave, state), do: {:noreply, state}

  def handle_info({port, {:data, {:noeol, part}}}, %{port: port} = state),
    do: {:noreply, %{state | buffer: state.buffer <> part}}

  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    whole = state.buffer <> line
    state = %{state | buffer: ""}

    case Jason.decode(whole) do
      {:ok, message} -> {:noreply, handle_message(message, state)}
      {:error, _} -> {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("file watcher #{state.id}: the shim exited (#{status})")

    {:noreply,
     set_status(%{state | port: nil}, false, "the file watcher stopped (exit #{status})")}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: close(state)

  ## The shim

  defp open(state) do
    case Ash.get(Projects.Project, state.id) do
      {:ok, project} ->
        port =
          Port.open({:spawn_executable, Longx.Shim.executable()}, [
            :binary,
            :exit_status,
            :use_stdio,
            {:line, 65_536},
            args: ["watch"]
          ])

        Port.command(port, Jason.encode!(FileRules.config(project)) <> "\n")
        await_ready(%{state | port: port, buffer: ""})

      {:error, _} ->
        set_status(state, false, "the project is gone")
    end
  end

  # the watches in place before anyone is answered: a subscribe queued behind this
  # returns once a change would be seen (the walk takes ~50 ms for 5000 directories)
  defp await_ready(%{port: port} = state) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case Jason.decode(line) do
          {:ok, %{"ready" => true} = message} -> handle_message(message, state)
          {:ok, message} -> await_ready(handle_message(message, state))
          {:error, _} -> await_ready(state)
        end

      {^port, {:exit_status, status}} ->
        set_status(
          %{state | port: nil},
          false,
          "the file watcher could not start (exit #{status})"
        )
    after
      10_000 -> set_status(state, false, "the file watcher did not start in 10 s")
    end
  end

  # the rules changed (a setting, git init): a new shim with the new config; what
  # the tree dims changed with them
  defp restart(state) do
    state = state |> close() |> open()
    broadcast(state.id, {:files_changed, state.id, []})
    state
  end

  # closing the port closes the shim's stdin: it removes its watches and exits
  defp close(%{port: port} = state) when is_port(port) do
    Port.close(port)
    %{state | port: nil}
  catch
    _, _ -> %{state | port: nil}
  end

  defp close(state), do: state

  defp handle_message(%{"ready" => true}, state), do: set_status(state, true, nil)

  defp handle_message(%{"error" => error}, state) do
    # most often the inotify limit: what could be watched is, the person told
    Longx.System.Faults.record(:watch, state.id, error)
    set_status(state, true, error)
  end

  # .git came or went: the config says whether .gitignore applies and .git is watched
  defp handle_message(%{"repo" => true}, state) do
    state = restart(state)
    broadcast(state.id, {:git_changed, state.id})
    state
  end

  defp handle_message(%{"paths" => paths} = batch, state) do
    id = state.id
    everything? = batch["rules"] == true or batch["overflow"] == true or batch["more"] == true

    if Enum.any?(paths, &(&1 == ".longx" or String.starts_with?(&1, ".longx/"))) or
         batch["overflow"] == true,
       do: broadcast(id, {:definition_changed, id})

    if batch["git"] == true or batch["overflow"] == true, do: broadcast(id, {:git_changed, id})

    cond do
      everything? -> broadcast(id, {:files_changed, id, []})
      paths != [] -> broadcast(id, {:files_changed, id, paths})
      true -> :ok
    end

    state
  end

  defp handle_message(_other, state), do: state

  defp set_status(state, watching, error) do
    status = %{watching: watching, error: error}

    if status != state.status,
      do: broadcast(state.id, {:watch_status, state.id, status})

    %{state | status: status}
  end

  defp broadcast(id, message),
    do: Phoenix.PubSub.broadcast(Longx.PubSub, Projects.topic(id), message)

  defp grace_ms,
    do: :longx |> Application.get_env(__MODULE__, []) |> Keyword.get(:grace_ms, 30_000)
end
