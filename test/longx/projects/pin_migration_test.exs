defmodule Longx.Projects.PinMigrationTest do
  use ExUnit.Case, async: false

  @repo :longx_pin_migration_test

  test "an existing project upgrades as unpinned and keeps its data" do
    db =
      Path.join(System.tmp_dir!(), "longx-pin-migration-#{System.unique_integer([:positive])}.db")

    on_exit(fn -> for suffix <- ["", "-wal", "-shm"], do: File.rm(db <> suffix) end)

    {:ok, connection} = Exqlite.Sqlite3.open(db)

    :ok =
      Exqlite.Sqlite3.execute(
        connection,
        "CREATE TABLE projects (id TEXT PRIMARY KEY, name TEXT)"
      )

    :ok =
      Exqlite.Sqlite3.execute(
        connection,
        "INSERT INTO projects VALUES ('old', 'Existing project')"
      )

    :ok = Exqlite.Sqlite3.close(connection)

    start_supervised!(
      {Longx.Repo, name: @repo, database: db, pool: DBConnection.ConnectionPool, pool_size: 2}
    )

    Longx.Repo.put_dynamic_repo(@repo)
    Code.require_file("../../../priv/repo/migrations/20261004113329_pin_projects.exs", __DIR__)

    assert :ok =
             Ecto.Migrator.up(
               Longx.Repo,
               20_261_004_113_329,
               Longx.Repo.Migrations.PinProjects,
               log: false
             )

    assert %{rows: [["old", "Existing project", 0]]} =
             Longx.Repo.query!("SELECT id, name, pinned FROM projects")
  end
end
