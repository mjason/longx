defmodule Longx.Projects.Tracker do
  @moduledoc """
  Keeps `Longx.Projects.Thread` / `Turn` rows in step with what the agents
  do.

  Per thread (subscribed on `track/1`): `turn/started` for a turn nobody
  sent through `Projects` (a child's report waking its parent, a goal's
  continuation) gets a row; `turn/completed` records status, time and the
  git HEAD after the turn; the first user message the preview; a
  `subAgentActivity` marks the child's row active / idle (and makes one when
  the kernel spawned a bare agent); a request the person has to answer
  (`longx/action/request`) goes to the notify feed.

  Stall watchdog: a turn whose thread has produced no event for
  `stall_after` (default 10 minutes; `config :longx, Longx.Projects.Tracker`)
  is interrupted; the turn ends `:interrupted` with an error saying so.
  """

  use GenServer

  alias Longx.Git
  alias Longx.Projects
  alias Longx.Projects.{Thread, Turn}
  alias Phoenix.PubSub

  require Logger

  @default_stall_after :timer.minutes(10)
  @default_tick :timer.seconds(30)

  defmodule State do
    @moduledoc false
    # tracked: kernel thread id → last event (monotonic ms)
    defstruct tracked: %{}, interrupted: MapSet.new(), timer: nil
  end

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Starts following the thread's events."
  @spec track(String.t()) :: :ok
  def track(kernel_thread_id), do: GenServer.call(__MODULE__, {:track, kernel_thread_id})

  @impl true
  def init(_opts), do: {:ok, schedule_tick(%State{})}

  @impl true
  def handle_call({:track, kernel_thread_id}, _from, state) do
    {:reply, :ok, follow(state, kernel_thread_id)}
  end

  # a thread already followed keeps its clock: a page joining it (host_thread
  # tracks on every join) is not progress — pages kept reopening a stuck
  # sub-agent and the watchdog never saw ten quiet minutes
  defp follow(%State{tracked: tracked} = state, kernel_thread_id) do
    if Map.has_key?(tracked, kernel_thread_id) do
      state
    else
      :ok = PubSub.subscribe(Longx.PubSub, Longx.Agent.ThreadState.topic(kernel_thread_id))
      # (re)arm the watchdog with the current settings for the new thread
      schedule_tick(%State{state | tracked: Map.put(tracked, kernel_thread_id, now())})
    end
  end

  @impl true
  def handle_info({:thread, _seq, method, params}, state) do
    state =
      case handle_event(method, params) do
        {:track, child_id} -> follow(state, child_id)
        _ -> state
      end

    {:noreply, touch(state, method, params["threadId"])}
  rescue
    e ->
      Logger.error("projects tracker failed on #{method}: #{Exception.message(e)}")
      {:noreply, state}
  end

  def handle_info(:tick, state) do
    {:noreply, state |> check_stalls() |> schedule_tick()}
  end

  def handle_info(_other, state), do: {:noreply, state}

  ## Thread events

  # a turn nobody sent through Projects — a child's report waking its parent,
  # a goal's continuation — gets a row like any other
  defp handle_event("turn/started", %{
         "threadId" => kernel_thread_id,
         "turn" => %{"id" => turn_id} = turn
       }) do
    with {:error, _} <- Projects.get_turn_by_kernel_id(turn_id),
         {:ok, %Thread{} = thread} <- Projects.get_thread_by_kernel_id(kernel_thread_id) do
      Projects.record_external_turn(thread, turn_id, from: turn["from"])
    end
  end

  defp handle_event("turn/completed", %{
         "threadId" => kernel_thread_id,
         "turn" => %{"id" => turn_id} = turn
       }) do
    with {:ok, %Turn{} = row} <- Projects.get_turn_by_kernel_id(turn_id),
         {:ok, %Thread{} = thread} <- Projects.get_thread_by_kernel_id(kernel_thread_id) do
      # a retract marks its row reverted before the interrupt that ends the
      # turn: that row is out of the history already, its ending is no news
      if row.status != :reverted do
        status = turn_status(turn["status"])
        error = get_in(turn, ["error", "message"]) || row.error

        Projects.complete_turn!(row, %{
          status: status,
          completed_at: DateTime.utc_now(),
          commit_after: head(thread.cwd),
          error: error,
          usage: if(is_map(turn["usage"]), do: turn["usage"], else: row.usage)
        })

        notify_turn_end(thread, status, error)
        # every failed turn, sub-agents' too: what the person will want to debug
        if status == :failed, do: Longx.Sentry.turn_failed(kernel_thread_id, turn_id, error)
      end

      Projects.touch_thread!(thread, %{status: :idle, last_activity_at: DateTime.utc_now()})
      Projects.broadcast_changed(thread.project_id)
    end
  end

  # a request the person has to answer (a tool's ask) — the phone's reason to buzz
  defp handle_event(
         "longx/action/request",
         %{"threadId" => kernel_thread_id, "requestId" => _} = params
       ) do
    with {:ok, %Thread{} = thread} <- Projects.get_thread_by_kernel_id(kernel_thread_id) do
      Projects.notify(thread, "approval",
        title: "等待你操作",
        body: request_summary(params, thread)
      )
    end
  end

  defp handle_event("item/completed", %{
         "threadId" => kernel_thread_id,
         "item" => %{"type" => "userMessage"} = item
       }) do
    with {:ok, %Thread{preview: nil} = thread} <-
           Projects.get_thread_by_kernel_id(kernel_thread_id),
         text when is_binary(text) <- user_text(item) do
      # a message from another agent or a watch carries its `[agent name] ` prefix
      # for the model; the list shows the words
      text = Regex.replace(~r/^\[agent [^\]]+\] /, text, "")
      Projects.touch_thread!(thread, %{preview: String.slice(text, 0, 200)})
      Projects.broadcast_changed(thread.project_id)
    end
  end

  # a child agent of a tracked thread: `Projects.spawn_native_agent/4` made its
  # row already; a bare spawn (a strategy plug in a test) gets one here. Its
  # topic is followed from now on so its turns get the same treatment.
  defp handle_event("item/completed", %{
         "threadId" => parent_id,
         "item" => %{
           "type" => "subAgentActivity",
           "agentThreadId" => child_id,
           "agentPath" => path,
           "kind" => kind
         }
       }) do
    with {:ok, %Thread{} = parent} <- Projects.get_thread_by_kernel_id(parent_id) do
      child =
        case Projects.get_thread_by_kernel_id(child_id) do
          {:ok, %Thread{} = child} ->
            child

          {:error, _} ->
            Projects.create_thread!(%{
              kernel_thread_id: child_id,
              project_id: parent.project_id,
              parent_thread_id: parent.id,
              agent_path: path,
              title: path |> String.split("/") |> List.last(),
              cwd: parent.cwd,
              model_slug: parent.model_slug,
              web_search: parent.web_search,
              status: :active
            })
        end

      status = if kind in ["started", "interacted"], do: :active, else: :idle
      Projects.touch_thread!(child, %{status: status, last_activity_at: DateTime.utc_now()})
      Projects.broadcast_changed(parent.project_id)
      {:track, child_id}
    else
      _ -> :ok
    end
  end

  defp handle_event(_method, _params), do: :ok

  ## Stall watchdog

  defp check_stalls(%State{tracked: tracked, interrupted: interrupted} = state) do
    stall_after = config(:stall_after, @default_stall_after)
    cutoff = now() - stall_after

    stalled =
      for {kernel_thread_id, last} <- tracked,
          last < cutoff,
          not MapSet.member?(interrupted, kernel_thread_id),
          {:ok, %Thread{} = thread} <- [Projects.get_thread_by_kernel_id(kernel_thread_id)],
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

        Projects.interrupt_turn(thread, turn.kernel_turn_id)
        Projects.broadcast_changed(thread.project_id)
        MapSet.put(acc, thread.kernel_thread_id)
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

  defp touch(%State{tracked: tracked, interrupted: interrupted} = state, method, kernel_thread_id) do
    interrupted =
      if method == "turn/completed",
        do: MapSet.delete(interrupted, kernel_thread_id),
        else: interrupted

    %State{
      state
      | tracked: Map.replace(tracked, kernel_thread_id, now()),
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

  # root threads only: a sub-agent's turn is a step of its parent's
  defp notify_turn_end(%Thread{parent_thread_id: nil} = thread, :completed, _error),
    do: Projects.notify(thread, "turn_completed", title: "完成了")

  defp notify_turn_end(%Thread{parent_thread_id: nil} = thread, :failed, error),
    do:
      Projects.notify(thread, "turn_failed",
        title: "出错了",
        body: error || Projects.thread_label(thread)
      )

  defp notify_turn_end(_thread, _status, _error), do: :ok

  defp request_summary(%{"title" => title}, _thread) when is_binary(title) and title != "",
    do: title

  defp request_summary(_params, thread), do: Projects.thread_label(thread)

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
