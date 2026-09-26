defmodule Longx.RepoTest do
  # SQLite answers "Database busy" at once — no busy_timeout wait — when a
  # transaction that began by reading (the default, deferred) tries to write
  # after another connection committed: it cannot upgrade a stale snapshot.
  # Oban's cron and pruner read then write in a transaction every minute on
  # the minute, and in production both failed so (Sentry LONX-D, LONX-E,
  # 2026-09-26, 0.95 s after the minute). Every transaction of the repo
  # begins IMMEDIATE: it takes the write lock first, and another writer waits.
  use ExUnit.Case, async: false

  @name :longx_repo_busy_test

  setup do
    db = Path.join(System.tmp_dir!(), "longx-repo-busy-#{System.unique_integer([:positive])}.db")

    on_exit(fn ->
      for suffix <- ["", "-wal", "-shm"], do: File.rm(db <> suffix)
    end)

    # the file ready before the pool opens it (two connections creating it
    # at once is a lock of its own)
    {:ok, conn} = Exqlite.Sqlite3.open(db)
    :ok = Exqlite.Sqlite3.execute(conn, "PRAGMA journal_mode=WAL")
    :ok = Exqlite.Sqlite3.execute(conn, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
    :ok = Exqlite.Sqlite3.close(conn)

    # the app's repo settings (busy_timeout, the transaction mode) on that
    # scratch file, a plain pool of two connections
    start_supervised!(
      {Longx.Repo, name: @name, database: db, pool: DBConnection.ConnectionPool, pool_size: 2}
    )

    Longx.Repo.put_dynamic_repo(@name)
    :ok
  end

  test "a transaction that reads before it writes is not refused when another write commits in between" do
    test = self()

    a =
      Task.async(fn ->
        Longx.Repo.put_dynamic_repo(@name)

        Longx.Repo.transaction(fn ->
          Longx.Repo.query!("SELECT count(*) FROM t")
          send(test, :read)

          receive do
            :go -> Longx.Repo.query!("INSERT INTO t (v) VALUES ('a')")
          end
        end)
      end)

    assert_receive :read, 5_000

    b =
      Task.async(fn ->
        Longx.Repo.put_dynamic_repo(@name)
        Longx.Repo.query("INSERT INTO t (v) VALUES ('b')")
      end)

    # let b reach the database before a writes
    receive do
    after
      200 -> :ok
    end

    send(a.pid, :go)
    assert {:ok, _} = Task.await(a, 30_000)
    assert {:ok, _} = Task.await(b, 30_000)
    assert %{rows: [[2]]} = Longx.Repo.query!("SELECT count(*) FROM t")
  end
end
