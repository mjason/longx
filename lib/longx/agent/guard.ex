defmodule Longx.Agent.Guard do
  @moduledoc """
  One agent's own supervisor — the OTP answer to "agents crash all the time".

  `Longx.Agent` is its one child, `:transient` and significant: a crash
  restarts the agent at once from the same options (`Longx.Agent.Kernel.Specs`
  holds them too), the restarted process settles what it finds half done
  (`Longx.Agent`'s load) and tells its parent; the idle exit (`:normal`) takes
  the guard down with it (`auto_shutdown: :any_significant`), so the next
  `ensure/1` starts a fresh guard on fresh options; crashing past the budget
  (`max_restarts` in a minute) ends the guard with
  `{:shutdown, :reached_max_restart_intensity}` — only this agent is gone, the
  `Longx.Agent.Supervisor` above (a DynamicSupervisor, whose intensity is
  shared by every agent) never sees a restart.

  A parent monitors its child's guard, not the child's pid: the guard stands
  for "the child is still there" across restarts.
  """

  use Supervisor

  @registry Longx.Agent.Registry
  @default_max_restarts 3

  def start_link(opts) do
    thread_id = Keyword.fetch!(opts, :thread_id)
    Supervisor.start_link(__MODULE__, opts, name: via(thread_id))
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :thread_id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :supervisor
    }
  end

  @spec whereis(String.t()) :: pid | nil
  def whereis(thread_id), do: GenServer.whereis(via(thread_id))

  defp via(thread_id), do: {:via, Registry, {@registry, {:guard, thread_id}}}

  @impl true
  def init(opts) do
    children = [
      %{
        id: Longx.Agent,
        start: {Longx.Agent, :start_link, [opts]},
        restart: :transient,
        significant: true,
        # a graceful stop finishes the callback in flight (a transcript write)
        shutdown: 15_000
      }
    ]

    Supervisor.init(children,
      strategy: :one_for_one,
      auto_shutdown: :any_significant,
      max_restarts: max_restarts(),
      max_seconds: 60
    )
  end

  @doc "How many crashes a minute a guard rides out before it gives up (`config :longx, Longx.Agent, max_restarts:`)."
  def max_restarts,
    do:
      :longx
      |> Application.get_env(Longx.Agent, [])
      |> Keyword.get(:max_restarts, @default_max_restarts)
end
