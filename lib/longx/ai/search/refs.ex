defmodule Longx.AI.Search.Refs do
  @moduledoc """
  Remembers what `turnNsearchM` / `turnNfetchM` reference ids meant, per codex
  session, so a later `open` / `find` command can resolve them. The gateway
  is otherwise stateless; this is the one bit of memory web search needs.

  Backed by a public ETS table owned by this process; entries older than
  `@ttl` are swept periodically.
  """

  use GenServer

  @table __MODULE__
  @ttl :timer.hours(24)
  @sweep_every :timer.minutes(30)

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Next turn number for `session` (0 on first use)."
  @spec next_turn(String.t()) :: non_neg_integer
  def next_turn(session) do
    :ets.update_counter(@table, {session, :turn}, {2, 1}, {{session, :turn}, -1})
  end

  @spec put(String.t(), String.t(), %{url: String.t(), title: String.t() | nil}) :: :ok
  def put(session, ref_id, %{url: url} = meta) do
    :ets.insert(
      @table,
      {{session, ref_id}, url, Map.get(meta, :title), System.monotonic_time(:millisecond)}
    )

    :ok
  end

  @spec fetch(String.t(), String.t()) ::
          {:ok, %{url: String.t(), title: String.t() | nil}} | :error
  def fetch(session, ref_id) do
    case :ets.lookup(@table, {session, ref_id}) do
      [{_, url, title, _}] -> {:ok, %{url: url, title: title}}
      [] -> :error
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = System.monotonic_time(:millisecond) - @ttl
    :ets.select_delete(@table, [{{:_, :_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_every)
end
