defmodule Longx.Migrator do
  @moduledoc """
  Runs the pending migrations at boot, before `Longx.Repo` starts, on a repo
  instance of its own with **one** connection.

  Why one connection: SQLite checks a `DROP COLUMN` against the
  connection's cached schema while parsing, before the schema-cookie check
  that would reload a stale cache. The chain adds a column in one migration
  and drops it two migrations later; on the app's pool the drop could land
  on a connection that had never seen the add and fail with "no such
  column" — 0.2.4's release could not boot on an empty data directory,
  while an upgraded install (whose database had the column all along) and
  `mix ecto.migrate` (a small pool, the same connection reused by luck)
  never showed it.

  A child of the supervision tree (`:ignore` once done, like
  `Ecto.Migrator`); `migrate/1` is the function, with `database:` for a
  test's temporary file.
  """

  require Logger

  @repo_name Longx.Migrator.Repo

  @spec child_spec(keyword) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  @spec start_link(keyword) :: :ignore
  def start_link(opts) do
    if Keyword.get(opts, :skip, false) do
      :ignore
    else
      :ok = migrate(opts)
      :ignore
    end
  end

  @doc "Every pending migration up, on a one-connection instance of `Longx.Repo` that is stopped afterwards."
  @spec migrate(keyword) :: :ok
  def migrate(opts \\ []) do
    # a plain pool whatever the app's config says (the test env's sandbox
    # pool would hand the migrations a connection nobody checked out)
    repo_opts =
      [name: @repo_name, pool_size: 1, pool: DBConnection.ConnectionPool]
      |> Keyword.merge(Keyword.take(opts, [:database]))

    {:ok, pid} = Longx.Repo.start_link(repo_opts)

    try do
      Longx.Repo.put_dynamic_repo(@repo_name)
      Ecto.Migrator.run(Longx.Repo, :up, all: true, dynamic_repo: @repo_name)
      :ok
    after
      Longx.Repo.put_dynamic_repo(Longx.Repo)
      Supervisor.stop(pid)
    end
  end
end
