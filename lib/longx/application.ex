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
      # Start a worker by calling: Longx.Worker.start_link(arg)
      # {Longx.Worker, arg},
      # Start to serve requests, typically the last entry
      LongxWeb.Endpoint
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
