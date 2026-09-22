defmodule Longx.Agent.ThreadState.Store do
  @moduledoc """
  ETS-backed storage for the materialised state of threads.

  Three public tables owned by this (long-lived) process, so the data
  outlives the per-thread `Longx.Agent.ThreadState` writer and readers never
  copy through a GenServer:

    * `meta`     — `{thread_id, %{seq, order, thread, turn, status, token_usage, goal}}`
    * `items`    — `{{thread_id, item_id}, order, item}`; `order` gives arrival order
    * `requests` — `{{thread_id, request_id}, order, method, params}`

  Writers for one thread must be serialised (the `ThreadState` process is
  the single writer) so `seq` stays strictly monotonic; reads are lock-free.
  Swapping the tables for DETS/Mnesia later only touches this module.
  """

  use GenServer

  alias Longx.Agent.Text

  @meta __MODULE__.Meta
  @items __MODULE__.Items
  @requests __MODULE__.Requests

  @empty_meta %{
    seq: 0,
    order: 0,
    thread: nil,
    turn: nil,
    # every turn seen, by id (its stamps, status and usage): the per-turn badge
    turns: %{},
    status: nil,
    token_usage: nil,
    # goal mode: the thread's goal (objective, status, budget, usage) or nil
    goal: nil,
    # what the model is writing right now (`turn/progress`): a call's name and bytes, or nil
    progress: nil,
    # an event's writes are in progress (see `event/2`)
    folding: false
  }

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    for table <- [@meta, @items, @requests] do
      :ets.new(table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    {:ok, %{}}
  end

  ## meta

  @spec meta(String.t()) :: map
  def meta(thread_id) do
    case :ets.lookup(@meta, thread_id) do
      [{_, meta}] -> meta
      [] -> @empty_meta
    end
  end

  @doc "Every thread whose view shows a turn in flight — what the Tracker's watchdog reconciles with the rows."
  @spec running() :: [String.t()]
  def running do
    :ets.select(@meta, [{{:"$1", %{turn: %{"status" => "inProgress"}}}, [], [:"$1"]}])
  end

  @doc "The rows' turns under the store's own (what the store saw since is newer)."
  @spec seed_turns(String.t(), %{optional(String.t()) => map}) :: :ok
  def seed_turns(thread_id, turns) when is_map(turns) do
    kept = meta(thread_id).turns

    put_meta(thread_id, %{
      turns: Map.merge(turns, kept, fn _id, row, seen -> Map.merge(row, seen) end)
    })
  end

  # a partial (turn/model) merges into what the turn is; the current turn is the merged one
  defp put_turn(thread_id, %{"id" => id} = turn) do
    merged = Map.merge(meta(thread_id).turns[id] || %{}, turn)
    put_meta(thread_id, %{turn: merged, turns: Map.put(meta(thread_id).turns, id, merged)})
  end

  defp put_turn(thread_id, turn), do: put_meta(thread_id, %{turn: turn})

  defp put_meta(thread_id, changes) do
    :ets.insert(@meta, {thread_id, Map.merge(meta(thread_id), changes)})
    :ok
  end

  @doc """
  Runs one event's writes as a unit the snapshot can see whole: the seq is
  allocated with the meta marked `folding` first, `fun` writes, the mark is
  cleared. `snapshot/1` retries while the mark is set or the seq moved under
  it, so a reader never sees an event's items with the seq before it (a
  duplicate on the client) or the seq without its items (a lost event).
  Returns the seq.
  """
  @spec event(String.t(), (-> any)) :: pos_integer
  def event(thread_id, fun) do
    %{seq: previous} = meta(thread_id)
    seq = previous + 1
    put_meta(thread_id, %{seq: seq, folding: true})

    try do
      fun.()
      seq
    rescue
      # an event the store cannot fold consumes no seq (the writer logs it)
      e ->
        put_meta(thread_id, %{seq: previous})
        reraise e, __STACKTRACE__
    after
      put_meta(thread_id, %{folding: false})
    end
  end

  @doc "Allocates the next event sequence number for the thread (an event with no writes)."
  @spec next_seq(String.t()) :: pos_integer
  def next_seq(thread_id), do: event(thread_id, fn -> :ok end)

  defp next_order(thread_id) do
    order = meta(thread_id).order + 1
    put_meta(thread_id, %{order: order})
    order
  end

  ## items

  @spec items(String.t()) :: [map]
  def items(thread_id) do
    @items
    |> :ets.match_object({{thread_id, :_}, :_, :_})
    |> Enum.sort_by(fn {_key, order, _item} -> order end)
    |> Enum.map(fn {_key, _order, item} -> item end)
  end

  @spec put_item(String.t(), map) :: :ok
  def put_item(thread_id, %{"id" => id} = item) do
    order =
      case :ets.lookup(@items, {thread_id, id}) do
        [{_, order, _}] -> order
        [] -> next_order(thread_id)
      end

    :ets.insert(@items, {{thread_id, id}, order, item})
    :ok
  end

  @doc "One item of the thread, or nil."
  @spec get_item(String.t(), String.t()) :: map | nil
  def get_item(thread_id, item_id) do
    case :ets.lookup(@items, {thread_id, item_id}) do
      [{_, _, item}] -> item
      [] -> nil
    end
  end

  # `index` = nil appends to a string field; an integer addresses one entry of
  # a list field (reasoning `summary`/`content` are `string[]`, and codex names
  # the entry with `summaryIndex`/`contentIndex`). A list field with no index
  # extends its last entry.
  @spec append(String.t(), String.t(), String.t(), String.t(), non_neg_integer | nil) :: :ok
  def append(thread_id, item_id, field, delta, index \\ nil) do
    item =
      case :ets.lookup(@items, {thread_id, item_id}) do
        [{_, _, item}] -> item
        [] -> %{"id" => item_id, "type" => "unknown"}
      end

    put_item(thread_id, Map.update(item, field, initial(delta, index), &extend(&1, delta, index)))
  end

  defp initial(delta, nil), do: delta
  defp initial(delta, index), do: extend([], delta, index)

  defp extend(list, delta, nil) when is_list(list) do
    case Enum.reverse(list) do
      [last | rest] when is_binary(last) -> Enum.reverse([last <> delta | rest])
      _ -> list ++ [delta]
    end
  end

  defp extend(list, delta, index) when is_list(list) do
    padded = list ++ List.duplicate("", max(index + 1 - length(list), 0))
    List.update_at(padded, index, &((&1 || "") <> delta))
  end

  defp extend(current, delta, nil), do: (current || "") <> delta
  defp extend(current, delta, index), do: extend(List.wrap(current), delta, index)

  ## requests

  @spec requests(String.t()) :: [%{id: term, method: String.t(), params: map}]
  def requests(thread_id) do
    @requests
    |> :ets.match_object({{thread_id, :_}, :_, :_, :_})
    |> Enum.sort_by(fn {_key, order, _m, _p} -> order end)
    |> Enum.map(fn {{_t, id}, _order, method, params} ->
      %{id: id, method: method, params: params}
    end)
  end

  @spec put_request(String.t(), term, String.t(), map) :: :ok
  def put_request(thread_id, id, method, params) do
    :ets.insert(@requests, {{thread_id, id}, next_order(thread_id), method, params})
    :ok
  end

  @spec delete_request(String.t(), term) :: :ok
  def delete_request(thread_id, id) do
    :ets.delete(@requests, {thread_id, id})
    :ok
  end

  @doc "Removes every item belonging to the given turns (a `thread/revert`)."
  @spec delete_turns(String.t(), [String.t()]) :: :ok
  def delete_turns(thread_id, turn_ids) do
    turn_ids = MapSet.new(turn_ids)

    @items
    |> :ets.match_object({{thread_id, :_}, :_, :_})
    |> Enum.each(fn {key, _order, item} ->
      if MapSet.member?(turn_ids, item["turnId"]), do: :ets.delete(@items, key)
    end)

    put_meta(thread_id, %{turns: Map.drop(meta(thread_id).turns, MapSet.to_list(turn_ids))})
  end

  ## folding notifications

  @doc "Applies one event (codex's vocabulary) to the thread's stored view."
  @spec fold(String.t(), String.t(), map) :: :ok
  def fold(t, "thread/started", %{"thread" => thread}), do: put_meta(t, %{thread: thread})
  def fold(t, "turn/started", %{"turn" => turn}), do: put_turn(t, turn)

  def fold(t, "turn/completed", %{"turn" => turn}) do
    put_meta(t, %{progress: nil})
    put_turn(t, turn)
  end

  def fold(t, "turn/progress", %{"progress" => progress}), do: put_meta(t, %{progress: progress})

  # what the turn runs on: onto the turn (its badge names the model and level)
  def fold(t, "turn/model", %{"turnId" => id} = p) when is_binary(id),
    do:
      put_turn(t, %{
        "id" => id,
        "model" => p["model"],
        "modelName" => p["name"],
        "effort" => p["effort"]
      })

  def fold(t, "thread/status/changed", %{"status" => status}), do: put_meta(t, %{status: status})

  def fold(t, "thread/tokenUsage/updated", %{"tokenUsage" => usage}),
    do: put_meta(t, %{token_usage: usage})

  # goal mode: one goal per thread, replaced whole on every update
  def fold(t, "thread/goal/updated", %{"goal" => goal}), do: put_meta(t, %{goal: goal})
  def fold(t, "thread/goal/cleared", _params), do: put_meta(t, %{goal: nil})

  # every item and delta scrubbed of bytes that are not UTF-8 (Longx.Agent.Text
  # says why): the snapshot and every event must encode to JSON
  def fold(t, "item/started", %{"item" => %{"id" => _} = item} = params),
    do: put_item(t, Text.deep(with_turn(item, params)))

  def fold(t, "item/completed", %{"item" => %{"id" => _} = item} = params),
    do: put_item(t, Text.deep(with_turn(item, params)))

  def fold(t, "item/agentMessage/delta", %{"itemId" => id, "delta" => d}),
    do: append(t, id, "text", Text.utf8(d))

  def fold(t, "item/reasoning/summaryTextDelta", %{"itemId" => id, "delta" => d} = p),
    do: append(t, id, "summary", Text.utf8(d), p["summaryIndex"])

  def fold(t, "item/reasoning/textDelta", %{"itemId" => id, "delta" => d} = p),
    do: append(t, id, "content", Text.utf8(d), p["contentIndex"])

  def fold(t, "item/commandExecution/outputDelta", %{"itemId" => id, "delta" => d}),
    do: append(t, id, "aggregatedOutput", Text.utf8(d))

  def fold(t, "item/fileChange/outputDelta", %{"itemId" => id, "delta" => d}),
    do: append(t, id, "output", Text.utf8(d))

  def fold(_t, _method, _params), do: :ok

  @doc "Seeds the view from a `thread/read` (`includeTurns: true`) result."
  @spec backfill(String.t(), map) :: :ok
  def backfill(t, %{"thread" => %{"turns" => turns} = thread}) when is_list(turns) do
    put_meta(t, %{thread: Map.delete(thread, "turns")})

    Enum.each(turns, fn %{"items" => items} = turn ->
      Enum.each(items, &put_item(t, Text.deep(Map.put(&1, "turnId", turn["id"]))))
      put_meta(t, %{turn: Map.delete(turn, "items")})
    end)
  end

  def backfill(t, %{"thread" => thread}), do: put_meta(t, %{thread: thread})
  def backfill(_t, _), do: :ok

  ## whole-thread views

  @spec snapshot(String.t()) :: map
  def snapshot(thread_id), do: snapshot(thread_id, 100)

  # a seqlock read: the meta before and after the items must agree and no
  # event may be mid-write; the writer is one process, so a retry is rare
  defp snapshot(thread_id, tries) do
    before = meta(thread_id)
    items = items(thread_id)
    requests = requests(thread_id)
    meta = meta(thread_id)

    if (before.folding or meta.folding or before.seq != meta.seq) and tries > 0 do
      snapshot(thread_id, tries - 1)
    else
      %{
        seq: meta.seq,
        thread_id: thread_id,
        thread: meta.thread,
        turn: meta.turn,
        turns: meta.turns,
        status: meta.status,
        token_usage: meta.token_usage,
        goal: meta.goal,
        progress: meta.progress,
        items: items,
        pending_requests: requests
      }
    end
  end

  @spec delete(String.t()) :: :ok
  def delete(thread_id) do
    :ets.delete(@meta, thread_id)
    :ets.match_delete(@items, {{thread_id, :_}, :_, :_})
    :ets.match_delete(@requests, {{thread_id, :_}, :_, :_, :_})
    :ok
  end

  defp with_turn(item, %{"turnId" => turn_id}), do: Map.put_new(item, "turnId", turn_id)
  defp with_turn(item, _), do: item
end
