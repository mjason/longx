defmodule Longx.Shim.Resources do
  @moduledoc """
  Resource reports outlive the shim's normal exit so its caller can inspect
  cleanup after `await_exit`. Live reports stay pinned; finished reports are
  kept briefly and bounded. This does not keep a command or its shim alive.
  """
  use GenServer

  @table __MODULE__
  @retention_ms 60_000
  @max_finished 2048

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def put(pid, key, value) when is_pid(pid) and key in [:resource_guard, :resource_exit],
    do: GenServer.call(__MODULE__, {:put, pid, key, value})

  def get(pid, key) when is_pid(pid) do
    case :ets.lookup(@table, pid) do
      [{^pid, reports, deadline}] ->
        if deadline == :infinity or deadline > now(), do: Map.get(reports, key)

      [] ->
        nil
    end
  end

  def get(nil, _key), do: nil
  def get(server, key), do: get(GenServer.whereis(server), key)

  @doc "Recent real task reports; the settings page must not confuse these with a preflight."
  def snapshots do
    for {pid, reports, deadline} <- :ets.tab2list(@table),
        deadline == :infinity or deadline > now() do
      %{
        live: deadline == :infinity and Process.alive?(pid),
        sequence: Map.get(reports, :sequence, 0),
        observed_at: Map.get(reports, :observed_at),
        guard: reports[:resource_guard],
        exit: reports[:resource_exit]
      }
    end
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    Process.send_after(self(), :sweep, @retention_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_call({:put, pid, key, value}, _from, monitors) do
    {reports, monitors} =
      case :ets.lookup(@table, pid) do
        [{^pid, reports, _}] ->
          {reports, monitors}

        [] ->
          ref = Process.monitor(pid)
          {%{}, Map.put(monitors, ref, pid)}
      end

    reports =
      reports
      |> Map.put(key, value)
      |> Map.put(:sequence, System.unique_integer([:monotonic, :positive]))
      |> Map.put(:observed_at, DateTime.utc_now() |> DateTime.to_iso8601())

    :ets.insert(@table, {pid, reports, :infinity})
    {:reply, :ok, monitors}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _}, monitors) do
    case :ets.lookup(@table, pid) do
      [{^pid, reports, _}] -> :ets.insert(@table, {pid, reports, now() + @retention_ms})
      [] -> :ok
    end

    sweep()
    {:noreply, Map.delete(monitors, ref)}
  end

  def handle_info(:sweep, monitors) do
    sweep()
    Process.send_after(self(), :sweep, @retention_ms)
    {:noreply, monitors}
  end

  defp sweep do
    finished =
      @table
      |> :ets.tab2list()
      |> Enum.reject(fn {_, _, deadline} -> deadline == :infinity end)
      |> Enum.sort_by(&elem(&1, 2), :desc)

    for {{pid, _, deadline}, index} <- Enum.with_index(finished),
        deadline <= now() or index >= @max_finished,
        do: :ets.delete(@table, pid)
  end

  defp now, do: System.monotonic_time(:millisecond)
end
