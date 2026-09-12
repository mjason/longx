defmodule Longx.Codex.Supervisor do
  @moduledoc """
  Supervises the node-wide `Longx.Codex.Connection`. A crash-looping
  app-server should not take the web app down: the restart intensity here is
  deliberately low, and if it is exhausted only this subtree dies.
  """

  use Supervisor

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Supervisor.init([Longx.Codex.Connection],
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 60
    )
  end
end
