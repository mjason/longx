defmodule Longx.Projects.Tracker do
  @moduledoc """
  Keeps `Longx.Projects.Thread` / `Turn` rows in step with what codex does:
  subscribes to each tracked thread's topic and, on `turn/completed`,
  records status, time and the git HEAD after the turn; on
  `turn/diff/updated` the diff; on the first user message the preview.
  """

  use GenServer

  alias Longx.Git
  alias Longx.Projects
  alias Longx.Projects.{Thread, Turn}
  alias Phoenix.PubSub

  require Logger

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Starts following the codex thread's events."
  @spec track(String.t()) :: :ok
  def track(codex_thread_id), do: GenServer.call(__MODULE__, {:track, codex_thread_id})

  @impl true
  def init(_opts), do: {:ok, MapSet.new()}

  @impl true
  def handle_call({:track, codex_thread_id}, _from, tracked) do
    unless MapSet.member?(tracked, codex_thread_id) do
      :ok = PubSub.subscribe(Longx.PubSub, Longx.Codex.ThreadState.topic(codex_thread_id))
    end

    {:reply, :ok, MapSet.put(tracked, codex_thread_id)}
  end

  @impl true
  def handle_info({:codex, _seq, method, params}, tracked) do
    handle_event(method, params)
    {:noreply, tracked}
  rescue
    e ->
      Logger.error("projects tracker failed on #{method}: #{Exception.message(e)}")
      {:noreply, tracked}
  end

  def handle_info(_other, tracked), do: {:noreply, tracked}

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
        error: get_in(turn, ["error", "message"])
      })

      Projects.touch_thread!(thread, %{status: :idle, last_activity_at: DateTime.utc_now()})
    end
  end

  defp handle_event("turn/diff/updated", %{"turnId" => turn_id, "diff" => diff}) do
    with {:ok, %Turn{} = row} <- Projects.get_turn_by_codex_id(turn_id),
         do: Projects.set_turn_diff!(row, %{diff: diff})
  end

  defp handle_event("item/completed", %{
         "threadId" => codex_thread_id,
         "item" => %{"type" => "userMessage"} = item
       }) do
    with {:ok, %Thread{preview: nil} = thread} <- Projects.get_thread_by_codex_id(codex_thread_id),
         text when is_binary(text) <- user_text(item) do
      Projects.touch_thread!(thread, %{preview: String.slice(text, 0, 200)})
    end
  end

  defp handle_event(_method, _params), do: :ok

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
