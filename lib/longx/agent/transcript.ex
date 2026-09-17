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
  @spec input([Item.t()]) :: [map]
  def input(items) do
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
