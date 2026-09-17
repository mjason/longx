defmodule Longx.Agent.Kernel.Asks do
  @moduledoc """
  The asks tools have open (`Longx.Agent.Context.ask/2`): findable by id
  from outside the kernel — the browser coming back to `/callback/<id>`
  after a login — through `Longx.Agent.Registry` under `{:ask, id}`,
  registered by the agent process that waits, so nothing outlives it; and
  the kernel's own settling and cancelling of them.
  """

  alias Longx.Agent.Kernel.State
  alias Longx.Agent.ThreadState

  @registry Longx.Agent.Registry

  @doc "Called by the waiting agent process: the ask is reachable by id."
  @spec register(String.t(), String.t()) :: :ok
  def register(ask_id, thread_id) do
    {:ok, _} = Registry.register(@registry, {:ask, ask_id}, thread_id)
    :ok
  end

  @spec forget(String.t()) :: :ok
  def forget(ask_id), do: Registry.unregister(@registry, {:ask, ask_id})

  @doc "The browser came back: the query answers the ask (`{:ok, %{\"query\" => params}}` to the tool)."
  @spec deliver(String.t(), map) :: :ok | {:error, :unknown}
  def deliver(ask_id, query) when is_map(query) do
    case Registry.lookup(@registry, {:ask, ask_id}) do
      [{_pid, thread_id}] -> Longx.Agent.respond(thread_id, ask_id, %{"query" => query})
      [] -> {:error, :unknown}
    end
  end

  ## The kernel's side

  # answers the waiting tool and takes the request off the thread
  def settle_ask(%State{thread_id: thread_id}, id, ask, reply) do
    if ask.timer, do: Process.cancel_timer(ask.timer)
    if ask.callback?, do: forget(id)
    ThreadState.resolve_request(thread_id, id)
    GenServer.reply(ask.from, reply)
    true
  end

  def cancel_asks(%State{asks: asks} = state) do
    for {id, ask} <- asks, do: settle_ask(state, id, ask, {:error, :cancelled})
    %{state | asks: %{}}
  end
end
