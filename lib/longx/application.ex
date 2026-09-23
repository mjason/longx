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
      # the migrations first, on one connection of their own (Longx.Migrator says why)
      {Longx.Migrator, skip: skip_migrations?()},
      Longx.Repo,
      # the search provider row the settings page edits (a release seeds nothing)
      Supervisor.child_spec({Task, fn -> {:ok, _} = Longx.AI.ensure_search_provider() end},
        id: :search_provider_row,
        restart: :temporary
      ),
      # error reporting, on when a DSN was saved (Longx.Sentry)
      Supervisor.child_spec({Task, fn -> Longx.Sentry.configure_from_settings() end},
        id: :sentry_dsn,
        restart: :temporary
      ),
      {DNSCluster, query: Application.get_env(:longx, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Longx.PubSub},
      # per-provider in-flight counters (Provider.max_concurrent_requests)
      Longx.AI.Gateway.Limiter,
      # the model requests' own HTTP pool: a connection idle past
      # `conn_max_idle_time` is replaced at checkout, never reused — an upstream
      # (or a proxy) may have dropped it without the close reaching us, and one
      # reused after ten idle minutes answered "socket closed"
      {Finch,
       name: Longx.AI.Finch,
       pools: %{
         default: [
           conn_max_idle_time:
             :longx
             |> Application.get_env(Longx.AI.Finch, [])
             |> Keyword.get(:conn_max_idle_time, 30_000)
         ]
       }},
      Longx.AI.Gateway.Log,
      # the server's recent faults, for the settings page and the status strip
      Longx.System.Faults,
      # the memory watchdog over the agents' commands (Longx.System.Pressure)
      {Registry, keys: :duplicate, name: Longx.System.Pressure.Registry},
      {Longx.System.Pressure, Application.get_env(:longx, Longx.System.Pressure, [])},
      # per-thread materialised view (Longx.Agent.ThreadState); the ETS store
      # outlives the per-thread writer processes
      Longx.Agent.ThreadState.Store,
      {Registry, keys: :unique, name: Longx.Agent.ThreadRegistry},
      {DynamicSupervisor, name: Longx.Agent.ThreadState.Supervisor, strategy: :one_for_one},
      # the agent kernel: one Longx.Agent per thread, its tasks
      {Registry, keys: :unique, name: Longx.Agent.Registry},
      {Task.Supervisor, name: Longx.Agent.TaskSupervisor},
      Longx.Agent.Definition.Loader.Cache,
      Longx.Agent.Kernel.Specs,
      # the one writer of transcript items (the agents' event log)
      Longx.Agent.Transcript.Writer,
      {DynamicSupervisor, name: Longx.Agent.Supervisor, strategy: :one_for_one},
      # keeps project thread/turn rows in step with the agents' events
      Longx.Projects.Tracker,
      # a project's file watcher, only while a page has it open
      {Registry, keys: :unique, name: Longx.Projects.WatcherRegistry},
      {DynamicSupervisor, name: Longx.Projects.WatcherSupervisor, strategy: :one_for_one},
      # OAuth2 logins in flight (Longx.Credentials), and the token refresh jobs (Oban)
      Longx.Credentials.Logins,
      # the watches' scripts run here, one task per run (Longx.Watches)
      {Task.Supervisor, name: Longx.Watches.TaskSupervisor},
      {Oban, Application.fetch_env!(:longx, Oban)},
      # rows a previous boot left running: no agent survives the BEAM, nor a watch's run
      Supervisor.child_spec(
        {Task,
         fn ->
           Longx.Projects.settle_after_restart()
           Longx.Watches.settle_after_restart()
         end},
        id: :settle_after_restart,
        restart: :temporary
      ),
      # Start to serve requests, typically the last entry
      LongxWeb.Endpoint,
      # permits for the headless browser (Longx.Browser), and its on-demand download
      Longx.Browser.Pool,
      {Task.Supervisor, name: Longx.Browser.TaskSupervisor},
      Longx.Browser.Installer,
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
