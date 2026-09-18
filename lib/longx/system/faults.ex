defmodule Longx.System.Faults do
  @moduledoc """
  What went wrong on the server, kept where the person can see it: an ETS
  ring of the last `keep` faults (`config :longx, Longx.System.Faults,
  keep:`, 100), each `%{kind, where, detail, at}`, newest first, with a
  count of the recent ones for the status strip.

  The socket loop of 0.2.5 was invisible until someone traced WebSocket
  frames: the serializer had been logging encode failures nobody read. Now
  the serializer (`:socket_encode`) and the wire cleaner (`:wire_clean`,
  naming the thread whose view held the term) record here, Settings →
  请求记录 lists them and the strip counts the last hour's.
  """

  use GenServer

  @table __MODULE__
  @default_keep 100

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec keep() :: pos_integer
  def keep, do: :longx |> Application.get_env(__MODULE__, []) |> Keyword.get(:keep, @default_keep)

  @doc "Remembers a fault. Safe from any process, before the table exists too (then dropped)."
  @spec record(atom, String.t() | nil, String.t()) :: :ok
  def record(kind, where, detail) when is_atom(kind) and is_binary(detail) do
    entry = %{kind: kind, where: where, detail: detail, at: DateTime.utc_now()}

    try do
      :ets.insert(@table, {System.unique_integer([:monotonic, :positive]), entry})
      trim()
      :ok
    rescue
      ArgumentError -> :ok
    end
  end

  @doc "The faults, newest first."
  @spec recent(pos_integer) :: [map]
  def recent(n \\ @default_keep) do
    @table
    |> :ets.tab2list()
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.take(n)
    |> Enum.map(&elem(&1, 1))
  rescue
    ArgumentError -> []
  end

  @spec count_since(DateTime.t()) :: non_neg_integer
  def count_since(%DateTime{} = since),
    do: Enum.count(recent(), &(DateTime.compare(&1.at, since) == :gt))

  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :ordered_set,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{}}
  end

  # keep the ring at `keep`: the oldest go
  defp trim do
    over = :ets.info(@table, :size) - keep()

    if over > 0 do
      @table
      |> :ets.tab2list()
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.take(over)
      |> Enum.each(fn {key, _} -> :ets.delete(@table, key) end)
    end
  end
end
