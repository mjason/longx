defmodule Longx.Agent.Transcript do
  @moduledoc """
  A thread's history as an append-only log of `Longx.Agent.Item`s: every
  Responses input item the model saw or produced (`input`) with its
  codex-shaped UI item when it shows (`ui`). The model's context is the
  fold of the log (`input/1`), the UI replays the `ui` items, and a
  restart rebuilds both — no other process holds the conversation.
  A revert is a truncation (`truncate!/2`); a deleted thread takes its log.
  """

  use Ash.Domain, otp_app: :longx

  alias Longx.Agent.Item

  resources do
    resource Item
  end

  @interrupted_output "[interrupted before the tool finished]"
  # the user's words kept verbatim across a compaction (codex: 20k tokens, ~4 bytes each)
  @keep_user_bytes 80_000

  # a compaction boundary: before it only the user's own messages survive
  # (newest first within the budget), then the summary, then what came after
  defp fold(items, keep_user_bytes) do
    case Enum.find_index(Enum.reverse(items), &(&1.kind == :compaction)) do
      nil ->
        items

      from_end ->
        at = length(items) - 1 - from_end
        {before, [summary | rest]} = Enum.split(items, at)

        kept =
          before
          |> Enum.filter(&(&1.kind == :user_message and user_words?(&1.input)))
          |> Enum.reverse()
          |> Enum.reduce_while({[], 0}, fn item, {acc, used} ->
            size = byte_size(Jason.encode!(item.input))

            if used + size > keep_user_bytes,
              do: {:halt, {acc, used}},
              else: {:cont, {[item | acc], used + size}}
          end)
          |> elem(0)

        kept ++ [summary | rest]
    end
  end

  # the Responses API wants every output of a batch of calls right behind the
  # calls: anything else that slipped in between (an image a tool attached
  # while a sibling call was still running, in 0.1.22) moves behind the outputs
  defp regroup(items), do: regroup(items, [], [])

  defp regroup([], acc, deferred), do: Enum.reverse(acc) ++ deferred

  defp regroup([%Item{kind: :function_call} = call | rest], acc, deferred) do
    {calls, rest} = Enum.split_while(rest, &(&1.kind == :function_call))
    calls = [call | calls]
    wanted = MapSet.new(calls, & &1.input["call_id"])
    {outputs, others, rest} = take_outputs(rest, wanted, [], [])
    regroup(rest, Enum.reverse(calls ++ outputs) ++ acc, deferred ++ others)
  end

  defp regroup([item | rest], acc, deferred),
    do: regroup(rest, [item | Enum.reverse(deferred) ++ acc], [])

  # the outputs of the batch, in order, and what stood between them
  defp take_outputs(rest, wanted, outputs, others) do
    if MapSet.size(wanted) == 0 do
      {Enum.reverse(outputs), Enum.reverse(others), rest}
    else
      case rest do
        [%Item{kind: :function_call_output, input: %{"call_id" => id}} = out | more] ->
          if MapSet.member?(wanted, id),
            do: take_outputs(more, MapSet.delete(wanted, id), [out | outputs], others),
            else: take_outputs(more, wanted, outputs, [out | others])

        [%Item{kind: kind} = item | more]
        when kind in [:user_message, :agent_message, :reasoning] ->
          take_outputs(more, wanted, outputs, [item | others])

        _ ->
          # a new batch of calls or the end: the missing outputs are closed later
          {Enum.reverse(outputs), Enum.reverse(others), rest}
      end
    end
  end

  defp user_words?(%{"role" => "user", "content" => content}) when is_list(content),
    do: Enum.any?(content, &(&1["type"] == "input_text"))

  defp user_words?(_), do: false

  @spec append!(map) :: Item.t()
  def append!(attrs), do: Ash.create!(Item, attrs, action: :append)

  @doc "The thread's items, oldest first."
  @spec items!(String.t()) :: [Item.t()]
  def items!(thread_id) do
    Item
    |> Ash.Query.for_read(:for_thread, %{thread_id: thread_id})
    |> Ash.read!()
  end

  @doc "The highest seq in the thread (0 when empty)."
  @spec last_seq(String.t()) :: non_neg_integer
  def last_seq(thread_id) do
    thread_id |> items!() |> Enum.map(& &1.seq) |> Enum.max(fn -> 0 end)
  end

  @doc "Drops one turn's items (a retract / revert)."
  @spec truncate!(String.t(), String.t()) :: :ok
  def truncate!(thread_id, turn_id) do
    Item
    |> Ash.Query.for_read(:for_turn, %{thread_id: thread_id, turn_id: turn_id})
    |> Ash.read!()
    |> Enum.each(&Ash.destroy!/1)
  end

  @doc "Drops the whole thread's log."
  @spec delete!(String.t()) :: :ok
  def delete!(thread_id) do
    thread_id |> items!() |> Enum.each(&Ash.destroy!/1)
  end

  @doc """
  The items as the model's input. A `function_call` whose output never
  arrived (a crash, a kill mid-tool) gets a synthetic output: the Responses
  API refuses a call without its result.
  """
  @spec input([Item.t()], keyword) :: [map]
  def input(items, opts \\ []) do
    items = items |> fold(Keyword.get(opts, :keep_user_bytes, @keep_user_bytes)) |> regroup()

    answered =
      for %Item{kind: :function_call_output, input: %{"call_id" => id}} <- items,
          into: MapSet.new(),
          do: id

    Enum.flat_map(items, fn
      %Item{kind: :function_call, input: %{"call_id" => id} = input} ->
        if MapSet.member?(answered, id),
          do: [input],
          else: [
            input,
            %{"type" => "function_call_output", "call_id" => id, "output" => @interrupted_output}
          ]

      %Item{input: input} ->
        [input]
    end)
  end
end
