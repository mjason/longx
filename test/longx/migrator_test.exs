defmodule Longx.MigratorTest do
  @moduledoc """
  The boot migrator: a fresh database migrates from nothing, on one
  connection. The chain has an `ADD COLUMN` followed two migrations later by
  its `DROP COLUMN`; SQLite checks a `DROP COLUMN` against the connection's
  cached schema at parse time, so on a pool the drop could land on a
  connection that had not seen the add ("no such column") — 0.2.4's release
  could not boot on an empty data dir.
  """
  use ExUnit.Case, async: false

  alias Longx.Migrator

  setup do
    dir = Path.join(System.tmp_dir!(), "longx-migrator-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{db: Path.join(dir, "fresh.db")}
  end

  test "a fresh database gets every migration, on a repo of its own that is gone afterwards", %{
    db: db
  } do
    refute File.exists?(db)
    assert :ok = Migrator.migrate(database: db)
    assert File.exists?(db)

    {:ok, conn} = Exqlite.Sqlite3.open(db)
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "select count(*) from schema_migrations")
    {:row, [applied]} = Exqlite.Sqlite3.step(conn, stmt)
    assert applied == length(Path.wildcard("priv/repo/migrations/*.exs"))

    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(conn, "select sql from sqlite_master where name = 'projects'")

    {:row, [sql]} = Exqlite.Sqlite3.step(conn, stmt)
    refute sql =~ "gpu_passthrough"
    Exqlite.Sqlite3.close(conn)

    # the migrating repo instance is stopped; the app's own repo untouched
    refute Process.whereis(Longx.Migrator.Repo)
    assert Process.whereis(Longx.Repo)

    # a second run has nothing to do
    assert :ok = Migrator.migrate(database: db)
  end
end
