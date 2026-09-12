defmodule Longx.Codex.ThreadState.Store do
  @moduledoc """
  ETS-backed storage for the materialised state of codex threads.

  Three public tables owned by this (long-lived) process, so the data
  outlives the per-thread `Longx.Codex.ThreadState` writer and readers never
  copy through a GenServer:

    * `meta`     — `{thread_id, %{seq, order, thread, turn, status, token_usage}}`
    * `items`    — `{{thread_id, item_id}, order, item}`; `order` gives arrival order
    * `requests` — `{{thread_id, request_id}, order, method, params}`

  Writers for one thread must be serialised (the `ThreadState` process is
  the single writer) so `seq` stays strictly monotonic; reads are lock-free.
  Swapping the tables for DETS/Mnesia later only touches this module.
  """

  use GenServer

  @meta __MODULE__.Meta
  @items __MODULE__.Items
  @requests __MODULE__.Requests

  @empty_meta %{seq: 0, order: 0, thread: nil, turn: nil, status: nil, token_usage: nil}

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

  defp put_meta(thread_id, changes) do
    :ets.insert(@meta, {thread_id, Map.merge(meta(thread_id), changes)})
    :ok
  end

  @doc "Allocates the next event sequence number for the thread."
  @spec next_seq(String.t()) :: pos_integer
  def next_seq(thread_id) do
    seq = meta(thread_id).seq + 1
    put_meta(thread_id, %{seq: seq})
    seq
  end

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

  @spec append(String.t(), String.t(), String.t(), String.t()) :: :ok
  def append(thread_id, item_id, field, delta) do
    item =
      case :ets.lookup(@items, {thread_id, item_id}) do
        [{_, _, item}] -> item
        [] -> %{"id" => item_id, "type" => "unknown"}
      end

    put_item(thread_id, Map.update(item, field, delta, &((&1 || "") <> delta)))
  end

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
  end

  ## folding notifications

  @doc "Applies one codex notification to the thread's stored view."
  @spec fold(String.t(), String.t(), map) :: :ok
  def fold(t, "thread/started", %{"thread" => thread}), do: put_meta(t, %{thread: thread})
  def fold(t, "turn/started", %{"turn" => turn}), do: put_meta(t, %{turn: turn})
  def fold(t, "turn/completed", %{"turn" => turn}), do: put_meta(t, %{turn: turn})
  def fold(t, "thread/status/changed", %{"status" => status}), do: put_meta(t, %{status: status})

  def fold(t, "thread/tokenUsage/updated", %{"tokenUsage" => usage}),
    do: put_meta(t, %{token_usage: usage})

  def fold(t, "item/started", %{"item" => %{"id" => _} = item} = params),
    do: put_item(t, with_turn(item, params))

  def fold(t, "item/completed", %{"item" => %{"id" => _} = item} = params),
    do: put_item(t, with_turn(item, params))

  def fold(t, "item/agentMessage/delta", %{"itemId" => id, "delta" => d}),
    do: append(t, id, "text", d)

  def fold(t, "item/reasoning/summaryTextDelta", %{"itemId" => id, "delta" => d}),
    do: append(t, id, "summary", d)

  def fold(t, "item/reasoning/textDelta", %{"itemId" => id, "delta" => d}),
    do: append(t, id, "content", d)

  def fold(t, "item/commandExecution/outputDelta", %{"itemId" => id, "delta" => d}),
    do: append(t, id, "aggregatedOutput", d)

  def fold(t, "item/fileChange/outputDelta", %{"itemId" => id, "delta" => d}),
    do: append(t, id, "output", d)

  def fold(t, "item/plan/delta", %{"itemId" => id, "delta" => d}), do: append(t, id, "text", d)

  def fold(_t, _method, _params), do: :ok

  @doc "Seeds the view from a `thread/read` (`includeTurns: true`) result."
  @spec backfill(String.t(), map) :: :ok
  def backfill(t, %{"thread" => %{"turns" => turns} = thread}) when is_list(turns) do
    put_meta(t, %{thread: Map.delete(thread, "turns")})

    Enum.each(turns, fn %{"items" => items} = turn ->
      Enum.each(items, &put_item(t, Map.put(&1, "turnId", turn["id"])))
      put_meta(t, %{turn: Map.delete(turn, "items")})
    end)
  end

  def backfill(t, %{"thread" => thread}), do: put_meta(t, %{thread: thread})
  def backfill(_t, _), do: :ok

  ## whole-thread views

  @spec snapshot(String.t()) :: map
  def snapshot(thread_id) do
    meta = meta(thread_id)

    %{
      seq: meta.seq,
      thread_id: thread_id,
      thread: meta.thread,
      turn: meta.turn,
      status: meta.status,
      token_usage: meta.token_usage,
      items: items(thread_id),
      pending_requests: requests(thread_id)
    }
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
