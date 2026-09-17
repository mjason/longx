defmodule Longx.Agent.Asks do
  @moduledoc """
  The asks a tool has open (`Longx.Agent.Context.ask/2` with `callback:
  true`), findable by id from outside the kernel — the browser coming back
  to `/callback/<id>` after a login. Kept in `Longx.Agent.Registry` under
  `{:ask, id}` by the agent process that waits, so nothing outlives it.
  """

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
end
