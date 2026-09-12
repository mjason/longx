defmodule Longx.AI.Gateway.Limiter do
  @moduledoc """
  In-flight request counter per provider, backing
  `Longx.AI.Provider.max_concurrent_requests`. A single ETS table with atomic
  counters: `acquire/2` takes a slot or answers `:busy`, `release/1` gives it
  back. Nothing is queued — the caller answers 429 and codex backs off and
  retries, which is what an upstream rate limit would have looked like too.
  """

  use GenServer

  @table __MODULE__

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Takes a slot for `key` unless `max` are already in flight. `nil` never refuses."
  @spec acquire(term, pos_integer | nil) :: :ok | :busy
  def acquire(key, nil) do
    :ets.update_counter(@table, key, {2, 1}, {key, 0})
    :ok
  end

  def acquire(key, max) when is_integer(max) and max > 0 do
    # bump, then step back if that overshot: the counter is the only truth
    case :ets.update_counter(@table, key, {2, 1}, {key, 0}) do
      n when n <= max ->
        :ok

      _ ->
        :ets.update_counter(@table, key, {2, -1, 0, 0})
        :busy
    end
  end

  @spec release(term) :: :ok
  def release(key) do
    :ets.update_counter(@table, key, {2, -1, 0, 0}, {key, 0})
    :ok
  end

  @spec in_flight(term) :: non_neg_integer
  def in_flight(key) do
    case :ets.lookup(@table, key) do
      [{_, n}] -> n
      [] -> 0
    end
  end

  @doc "Runs `fun` holding a slot; `{:ok, result}` or `:busy` without running it."
  @spec run(term, pos_integer | nil, (-> result)) :: {:ok, result} | :busy when result: term
  def run(key, max, fun) do
    case acquire(key, max) do
      :ok ->
        try do
          {:ok, fun.()}
        after
          release(key)
        end

      :busy ->
        :busy
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, %{}}
  end
end
