defmodule Longx.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # One gateway token per boot; handed to codex-app-server when it is spawned.
    Longx.AI.Gateway.Token.generate!()

    children = [
      LongxWeb.Telemetry,
      Longx.Vault,
      Longx.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:longx, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:longx, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Longx.PubSub},
      # reference-id memory for codex web search (Longx.AI.Search)
      Longx.AI.Search.Refs,
      # per-provider in-flight counters (Provider.max_concurrent_requests)
      Longx.AI.Gateway.Limiter,
      # per-thread materialised codex state (Longx.Codex.ThreadState); the ETS
      # store outlives the per-thread writer processes
      Longx.Codex.ThreadState.Store,
      {Registry, keys: :unique, name: Longx.Codex.ThreadRegistry},
      {DynamicSupervisor, name: Longx.Codex.ThreadState.Supervisor, strategy: :one_for_one},
      # dynamic tool calls and other async work for the codex connection
      {Task.Supervisor, name: Longx.Codex.TaskSupervisor},
      # keeps project thread/turn rows in step with codex events
      Longx.Projects.Tracker,
      # Start a worker by calling: Longx.Worker.start_link(arg)
      # {Longx.Worker, arg},
      # Start to serve requests, typically the last entry
      LongxWeb.Endpoint
      # The bundled codex-app-server needs the endpoint's port for its gateway URL
      | codex_children(codex_autostart?())
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

  # config :longx, Longx.Codex.Connection, autostart: false (test) keeps codex out
  # of the tree; tests start their own connections against a fake server.
  defp codex_autostart? do
    :longx |> Application.get_env(Longx.Codex.Connection, []) |> Keyword.get(:autostart, true)
  end

  defp codex_children(true), do: [Longx.Codex.Supervisor]
  defp codex_children(false), do: []

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end
