defmodule Longx.Codex.ThreadState.View do
  @moduledoc """
  The materialised state of one codex thread: the fold of every notification
  seen so far. Pure — `fold/3` is what makes "refresh the page mid-turn"
  work: whatever a late subscriber missed is already folded in here.

  Items keep codex's own camelCase shape; streaming deltas are appended in
  place and `item/completed` replaces the item wholesale.
  """

  defstruct thread_id: nil,
            thread: nil,
            turn: nil,
            status: nil,
            token_usage: nil,
            item_ids: [],
            items: %{},
            requests: %{}

  @type t :: %__MODULE__{}

  @spec new(String.t()) :: t
  def new(thread_id), do: %__MODULE__{thread_id: thread_id}

  @doc "Items in arrival order."
  @spec items(t) :: [map]
  def items(%__MODULE__{item_ids: ids, items: items}),
    do: ids |> Enum.reverse() |> Enum.map(&Map.fetch!(items, &1))

  @spec pending_requests(t) :: [%{id: term, method: String.t(), params: map}]
  def pending_requests(%__MODULE__{requests: requests}) do
    requests |> Map.values() |> Enum.sort_by(& &1.seq)
  end

  @spec fold(t, {String.t(), map}) :: t
  def fold(view, {method, params}), do: fold(view, method, params)

  @spec fold(t, String.t(), map) :: t
  def fold(view, "thread/started", %{"thread" => thread}), do: %{view | thread: thread}
  def fold(view, "turn/started", %{"turn" => turn}), do: %{view | turn: turn}
  def fold(view, "turn/completed", %{"turn" => turn}), do: %{view | turn: turn}
  def fold(view, "thread/status/changed", %{"status" => status}), do: %{view | status: status}

  def fold(view, "thread/tokenUsage/updated", %{"tokenUsage" => usage}),
    do: %{view | token_usage: usage}

  def fold(view, "item/started", %{"item" => %{"id" => _} = item} = params),
    do: put_item(view, with_turn(item, params))

  def fold(view, "item/completed", %{"item" => %{"id" => _} = item} = params),
    do: put_item(view, with_turn(item, params))

  def fold(view, "item/agentMessage/delta", %{"itemId" => id, "delta" => d}),
    do: append(view, id, "text", d)

  def fold(view, "item/reasoning/summaryTextDelta", %{"itemId" => id, "delta" => d}),
    do: append(view, id, "summary", d)

  def fold(view, "item/reasoning/textDelta", %{"itemId" => id, "delta" => d}),
    do: append(view, id, "content", d)

  def fold(view, "item/commandExecution/outputDelta", %{"itemId" => id, "delta" => d}),
    do: append(view, id, "aggregatedOutput", d)

  def fold(view, "item/fileChange/outputDelta", %{"itemId" => id, "delta" => d}),
    do: append(view, id, "output", d)

  def fold(view, "item/plan/delta", %{"itemId" => id, "delta" => d}),
    do: append(view, id, "text", d)

  def fold(view, _method, _params), do: view

  @doc "Registers a server → client request awaiting an answer."
  @spec put_request(t, term, String.t(), map) :: t
  def put_request(%__MODULE__{requests: requests} = view, id, method, params) do
    entry = %{id: id, method: method, params: params, seq: map_size(requests)}
    %{view | requests: Map.put(requests, id, entry)}
  end

  @spec resolve_request(t, term) :: t
  def resolve_request(%__MODULE__{requests: requests} = view, id),
    do: %{view | requests: Map.delete(requests, id)}

  @doc "Seeds the view from a `thread/read` (`includeTurns: true`) result."
  @spec backfill(t, map) :: t
  def backfill(view, %{"thread" => %{"turns" => turns} = thread}) when is_list(turns) do
    view = %{view | thread: Map.delete(thread, "turns")}

    Enum.reduce(turns, view, fn %{"items" => items} = turn, view ->
      view = Enum.reduce(items, view, &put_item(&2, Map.put(&1, "turnId", turn["id"])))
      %{view | turn: Map.delete(turn, "items")}
    end)
  end

  def backfill(view, %{"thread" => thread}), do: %{view | thread: thread}
  def backfill(view, _), do: view

  ## helpers

  defp with_turn(item, %{"turnId" => turn_id}), do: Map.put_new(item, "turnId", turn_id)
  defp with_turn(item, _), do: item

  defp put_item(%__MODULE__{items: items, item_ids: ids} = view, %{"id" => id} = item) do
    ids = if Map.has_key?(items, id), do: ids, else: [id | ids]
    %{view | items: Map.put(items, id, item), item_ids: ids}
  end

  defp append(view, id, field, delta) do
    item = Map.get(view.items, id, %{"id" => id, "type" => "unknown"})
    put_item(view, Map.update(item, field, delta, &((&1 || "") <> delta)))
  end
end
