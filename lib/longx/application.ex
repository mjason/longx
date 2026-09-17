defmodule Longx.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      LongxWeb.Telemetry,
      Longx.Vault,
      Longx.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:longx, :ecto_repos), skip: skip_migrations?()},
      # the search provider row the settings page edits (a release seeds nothing)
      Supervisor.child_spec({Task, fn -> {:ok, _} = Longx.AI.ensure_search_provider() end},
        id: :search_provider_row,
        restart: :temporary
      ),
      {DNSCluster, query: Application.get_env(:longx, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Longx.PubSub},
      # per-provider in-flight counters (Provider.max_concurrent_requests)
      Longx.AI.Gateway.Limiter,
      Longx.AI.Gateway.Log,
      # per-thread materialised view (Longx.Agent.ThreadState); the ETS store
      # outlives the per-thread writer processes
      Longx.Agent.ThreadState.Store,
      {Registry, keys: :unique, name: Longx.Agent.ThreadRegistry},
      {DynamicSupervisor, name: Longx.Agent.ThreadState.Supervisor, strategy: :one_for_one},
      # the agent kernel: one Longx.Agent per thread, its tasks
      {Registry, keys: :unique, name: Longx.Agent.Registry},
      {Task.Supervisor, name: Longx.Agent.TaskSupervisor},
      Longx.Agent.Loader.Cache,
      Longx.Agent.Specs,
      {DynamicSupervisor, name: Longx.Agent.Supervisor, strategy: :one_for_one},
      # keeps project thread/turn rows in step with the agents' events
      Longx.Projects.Tracker,
      # rows a previous boot left running: no agent survives the BEAM
      Supervisor.child_spec({Task, fn -> Longx.Projects.settle_after_restart() end},
        id: :settle_after_restart,
        restart: :temporary
      ),
      # Start to serve requests, typically the last entry
      LongxWeb.Endpoint,
      # permits for the headless browser (Longx.Browser)
      Longx.Browser.Pool,
      # new releases on GitHub, and the upgrade itself (Longx.Upgrade)
      {Task.Supervisor, name: Longx.Upgrade.TaskSupervisor},
      Longx.Upgrade
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Longx.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    LongxWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end
