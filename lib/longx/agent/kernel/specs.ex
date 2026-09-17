defmodule Longx.Agent.Kernel.Specs do
  @moduledoc """
  What every agent was started with, by thread id — so an agent that left
  (idle timeout, a crash) comes back the same on demand
  (`Longx.Agent.ensure_alive/1`). An ETS table this process owns; a BEAM
  restart forgets it, and `Longx.Projects` rebuilds a thread's agent from
  its row then.
  """

  use GenServer

  @table :longx_agent_specs

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec put(String.t(), keyword) :: :ok
  def put(thread_id, opts), do: GenServer.call(__MODULE__, {:put, thread_id, opts})

  @spec get(String.t()) :: keyword | nil
  def get(thread_id) do
    case :ets.lookup(@table, thread_id) do
      [{^thread_id, opts}] -> opts
      [] -> nil
    end
  end

  @spec delete(String.t()) :: :ok
  def delete(thread_id), do: GenServer.call(__MODULE__, {:delete, thread_id})

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:put, id, opts}, _from, state) do
    :ets.insert(@table, {id, opts})
    {:reply, :ok, state}
  end

  def handle_call({:delete, id}, _from, state) do
    :ets.delete(@table, id)
    {:reply, :ok, state}
  end
end
