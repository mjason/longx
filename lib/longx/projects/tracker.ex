defmodule Longx.Projects.Tracker do
  @moduledoc """
  Keeps `Longx.Projects.Thread` / `Turn` rows in step with what codex does,
  and cleans up after it when it does not.

  Per thread (subscribed on `track/1`): `turn/completed` records status,
  time and the git HEAD after the turn; `turn/diff/updated` the diff; the
  first user message the preview.

  Per project's codex (`"codex:connection"`):
    * `:down` — every turn still `:in_progress` in that project fails with
      "codex restarted"; threads that were active become `:disconnected`
    * `:ready` — `:disconnected` threads are resumed on the new process
      (→ `:idle`), or marked `:unrecoverable` when codex no longer knows them

  Stall watchdog: a turn whose thread has produced no event for
  `stall_after` (default 10 minutes; `config :longx, Longx.Projects.Tracker`)
  is interrupted; the turn ends `:interrupted` with an error saying so.
  """

  use GenServer

  alias Longx.Codex.Pool
  alias Longx.Git
  alias Longx.Projects
  alias Longx.Projects.{Thread, Turn}
  alias Phoenix.PubSub

  require Logger

  @default_stall_after :timer.minutes(10)
  @default_tick :timer.seconds(30)

  defmodule State do
    @moduledoc false
    # tracked: codex thread id → last event (monotonic ms)
    defstruct tracked: %{}, interrupted: MapSet.new(), timer: nil
  end

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Starts following the codex thread's events."
  @spec track(String.t()) :: :ok
  def track(codex_thread_id), do: GenServer.call(__MODULE__, {:track, codex_thread_id})

  @impl true
  def init(_opts) do
    :ok = PubSub.subscribe(Longx.PubSub, "codex:connection")
    {:ok, schedule_tick(%State{})}
  end

  @impl true
  def handle_call({:track, codex_thread_id}, _from, state) do
    {:reply, :ok, follow(state, codex_thread_id)}
  end

  defp follow(%State{tracked: tracked} = state, codex_thread_id) do
    unless Map.has_key?(tracked, codex_thread_id) do
      :ok = PubSub.subscribe(Longx.PubSub, Longx.Codex.ThreadState.topic(codex_thread_id))
    end

    # (re)arm the watchdog with the current settings for the new thread
    schedule_tick(%State{state | tracked: Map.put(tracked, codex_thread_id, now())})
  end

  @impl true
  def handle_info({:codex, _seq, method, params}, state) do
    state =
      case handle_event(method, params) do
        {:track, child_codex_id} -> follow(state, child_codex_id)
        _ -> state
      end

    {:noreply, touch(state, method, params["threadId"])}
  rescue
    e ->
      Logger.error("projects tracker failed on #{method}: #{Exception.message(e)}")
      {:noreply, state}
  end

  def handle_info({:codex_connection, project_id, :down}, state) when is_binary(project_id) do
    codex_down(project_id)
    {:noreply, state}
  end

  def handle_info({:codex_connection, project_id, :ready}, state) when is_binary(project_id) do
    # resuming talks to codex; keep the tracker itself responsive
    Task.Supervisor.start_child(Longx.Codex.TaskSupervisor, fn -> codex_back(project_id) end)
    {:noreply, state}
  end

  def handle_info(:tick, state) do
    {:noreply, state |> check_stalls() |> schedule_tick()}
  end

  def handle_info(_other, state), do: {:noreply, state}

  ## Thread events

  defp handle_event("turn/completed", %{
         "threadId" => codex_thread_id,
         "turn" => %{"id" => turn_id} = turn
       }) do
    with {:ok, %Turn{} = row} <- Projects.get_turn_by_codex_id(turn_id),
         {:ok, %Thread{} = thread} <- Projects.get_thread_by_codex_id(codex_thread_id) do
      Projects.complete_turn!(row, %{
        status: turn_status(turn["status"]),
        completed_at: DateTime.utc_now(),
        commit_after: head(thread.cwd),
        error: get_in(turn, ["error", "message"]) || row.error
      })

      Projects.touch_thread!(thread, %{status: :idle, last_activity_at: DateTime.utc_now()})
      Projects.broadcast_changed(thread.project_id)
    end
  end

  defp handle_event("turn/diff/updated", %{
         "threadId" => codex_thread_id,
         "turnId" => turn_id,
         "diff" => diff
       }) do
    with {:ok, %Turn{} = row} <- Projects.get_turn_by_codex_id(turn_id),
         {:ok, %Thread{} = thread} <- Projects.get_thread_by_codex_id(codex_thread_id) do
      Projects.set_turn_diff!(row, %{diff: diff})
      Projects.broadcast_changed(thread.project_id)
    end
  end

  defp handle_event("item/completed", %{
         "threadId" => codex_thread_id,
         "item" => %{"type" => "userMessage"} = item
       }) do
    with {:ok, %Thread{preview: nil} = thread} <- Projects.get_thread_by_codex_id(codex_thread_id),
         text when is_binary(text) <- user_text(item) do
      Projects.touch_thread!(thread, %{preview: String.slice(text, 0, 200)})
      Projects.broadcast_changed(thread.project_id)
    end
  end

  # codex names a thread from its first exchange; that fills an empty title
  # only — a title the person chose (rename) is theirs
  defp handle_event("thread/name/updated", %{
         "threadId" => codex_thread_id,
         "threadName" => name
       })
       when is_binary(name) and name != "" do
    with {:ok, %Thread{title: nil} = thread} <- Projects.get_thread_by_codex_id(codex_thread_id) do
      Projects.touch_thread!(thread, %{title: String.slice(name, 0, 200)})
      Projects.broadcast_changed(thread.project_id)
    end
  end

  # a sub-agent codex spawned inside a tracked thread: a row of its own under
  # the parent (same project / cwd; codex sends no thread/started for it), its
  # topic followed from now on so its turns get the same treatment
  defp handle_event("item/completed", %{
         "threadId" => parent_codex_id,
         "item" => %{
           "type" => "subAgentActivity",
           "agentThreadId" => child_codex_id,
           "agentPath" => path,
           "kind" => kind
         }
       }) do
    with {:ok, %Thread{} = parent} <- Projects.get_thread_by_codex_id(parent_codex_id) do
      child =
        case Projects.get_thread_by_codex_id(child_codex_id) do
          {:ok, %Thread{} = child} ->
            child

          {:error, _} ->
            Projects.create_thread!(%{
              codex_thread_id: child_codex_id,
              project_id: parent.project_id,
              parent_thread_id: parent.id,
              agent_path: path,
              title: path |> String.split("/") |> List.last(),
              cwd: parent.cwd,
              model_slug: parent.model_slug,
              approval_policy: parent.approval_policy,
              sandbox: parent.sandbox,
              network_access: parent.network_access,
              web_search: parent.web_search,
              multi_agent: parent.multi_agent,
              tools: parent.tools,
              status: :active
            })
        end

      status = if kind in ["started", "interacted"], do: :active, else: :idle
      Projects.touch_thread!(child, %{status: status, last_activity_at: DateTime.utc_now()})
      Projects.broadcast_changed(parent.project_id)
      {:track, child_codex_id}
    else
      _ -> :ok
    end
  end

  defp handle_event(_method, _params), do: :ok

  ## Codex lifecycle

  defp codex_down(project_id) do
    now = DateTime.utc_now()

    for turn <- Projects.list_turns_in_progress!(project_id) do
      Projects.complete_turn!(turn, %{
        status: :failed,
        completed_at: now,
        error: "codex restarted while this turn was running"
      })
    end

    # idle threads need nothing now: they are resumed lazily on their next
    # message (Longx.Projects.send_message/3)
    for thread <- Projects.list_threads_with_status!(project_id, :active) do
      Projects.touch_thread!(thread, %{status: :disconnected})
    end

    Projects.broadcast_changed(project_id)
  rescue
    e -> Logger.error("projects tracker: codex down cleanup failed: #{Exception.message(e)}")
  end

  defp codex_back(project_id) do
    with {:ok, conn} <- Pool.connection(project_id) do
      for thread <- Projects.list_threads_with_status!(project_id, :disconnected) do
        case Longx.Codex.Thread.resume(thread.codex_thread_id, conn: conn) do
          {:ok, _} ->
            Projects.touch_thread!(thread, %{status: :idle})

          {:error, reason} ->
            Logger.warning(
              "projects tracker: thread #{thread.codex_thread_id} could not be resumed: #{inspect(reason)}"
            )

            Projects.touch_thread!(thread, %{status: :unrecoverable})
        end
      end

      Projects.broadcast_changed(project_id)
    end
  rescue
    e -> Logger.error("projects tracker: resume after restart failed: #{Exception.message(e)}")
  end

  ## Stall watchdog

  defp check_stalls(%State{tracked: tracked, interrupted: interrupted} = state) do
    stall_after = config(:stall_after, @default_stall_after)
    cutoff = now() - stall_after

    stalled =
      for {codex_thread_id, last} <- tracked,
          last < cutoff,
          not MapSet.member?(interrupted, codex_thread_id),
          {:ok, %Thread{} = thread} <- [Projects.get_thread_by_codex_id(codex_thread_id)],
          turn <- running_turn(thread),
          do: {thread, turn}

    interrupted =
      Enum.reduce(stalled, interrupted, fn {thread, turn}, acc ->
        Logger.warning(
          "projects tracker: turn #{turn.id} made no progress for #{div(stall_after, 1000)}s; interrupting"
        )

        Projects.complete_turn!(turn, %{
          status: :in_progress,
          error: "no progress for #{div(stall_after, 1000)} seconds; interrupted"
        })

        Longx.Codex.Thread.interrupt(thread.codex_thread_id, turn.codex_turn_id)
        Projects.broadcast_changed(thread.project_id)
        MapSet.put(acc, thread.codex_thread_id)
      end)

    %State{state | interrupted: interrupted}
  rescue
    e ->
      Logger.error("projects tracker: stall check failed: #{Exception.message(e)}")
      state
  end

  defp running_turn(%Thread{} = thread) do
    thread |> Projects.list_turns!() |> Enum.filter(&(&1.status == :in_progress)) |> Enum.take(1)
  end

  # any event on a thread is progress; a turn ending clears its interrupt mark
  defp touch(state, _method, nil), do: state

  defp touch(%State{tracked: tracked, interrupted: interrupted} = state, method, codex_thread_id) do
    interrupted =
      if method == "turn/completed",
        do: MapSet.delete(interrupted, codex_thread_id),
        else: interrupted

    %State{
      state
      | tracked: Map.replace(tracked, codex_thread_id, now()),
        interrupted: interrupted
    }
  end

  defp schedule_tick(%State{timer: timer} = state) do
    if timer, do: Process.cancel_timer(timer)
    %State{state | timer: Process.send_after(self(), :tick, config(:tick, @default_tick))}
  end

  defp config(key, default),
    do: :longx |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)

  defp now, do: System.monotonic_time(:millisecond)

  defp turn_status("completed"), do: :completed
  defp turn_status("interrupted"), do: :interrupted
  defp turn_status(_), do: :failed

  defp user_text(%{"content" => content}) when is_list(content) do
    content |> Enum.filter(&(&1["type"] == "text")) |> Enum.map_join(" ", & &1["text"])
  end

  defp user_text(_), do: nil

  defp head(dir) do
    case Git.head(dir) do
      {:ok, sha} -> sha
      _ -> nil
    end
  end
end
