defmodule Longx.ObanEngineTest do
  use ExUnit.Case, async: false

  @repo :longx_oban_busy_repo
  @oban :longx_oban_busy

  defmodule Migration do
    use Ecto.Migration
    def up, do: Oban.Migrations.SQLite.up([])
  end

  defmodule Worker do
    use Oban.Worker, queue: :busy
    @impl true
    def perform(%{args: %{"to" => to}}) do
      target = to |> String.to_charlist() |> :erlang.list_to_pid()
      send(target, {:worker_started, self()})

      receive do
        :finish -> :ok
      end
    end
  end

  setup do
    db = Path.join(System.tmp_dir!(), "longx-oban-busy-#{System.unique_integer([:positive])}.db")
    {:ok, initial} = Exqlite.Sqlite3.open(db)
    :ok = Exqlite.Sqlite3.execute(initial, "PRAGMA journal_mode=WAL")
    :ok = Exqlite.Sqlite3.close(initial)

    on_exit(fn ->
      for suffix <- ["", "-wal", "-shm"], do: File.rm(db <> suffix)
    end)

    start_supervised!(
      {Longx.Repo,
       name: @repo,
       database: db,
       pool: DBConnection.ConnectionPool,
       pool_size: 3,
       busy_timeout: 30}
    )

    Longx.Repo.put_dynamic_repo(@repo)
    :ok = Ecto.Migrator.up(Longx.Repo, 1, Migration, log: false)

    start_supervised!(
      {Oban,
       name: @oban,
       repo: Longx.Repo,
       get_dynamic_repo: fn -> @repo end,
       engine: Longx.ObanEngine,
       prefix: false,
       peer: Oban.Peers.Isolated,
       notifier: Oban.Notifiers.PG,
       plugins: [],
       testing: :disabled,
       queues: [busy: [limit: 2, refresh_interval: 100]]}
    )

    %{db: db}
  end

  test "refused fetch keeps the producer and its running worker alive, then resumes", %{db: db} do
    to = self() |> :erlang.pid_to_list() |> List.to_string()
    {:ok, first} = Oban.insert(@oban, Worker.new(%{"to" => to}))
    assert_receive {:worker_started, worker}, 5_000
    producer = Oban.Registry.whereis(@oban, {:producer, "busy"})
    :ok = :sys.suspend(producer)
    {:ok, second} = Oban.insert(@oban, Worker.new(%{"to" => to}))
    {:ok, lock} = Exqlite.Sqlite3.open(db)

    try do
      :ok = Exqlite.Sqlite3.execute(lock, "BEGIN IMMEDIATE")
      send(producer, :dispatch)
      :ok = :sys.resume(producer)
      _ = :sys.get_state(producer, 5_000)
      assert Oban.Registry.whereis(@oban, {:producer, "busy"}) == producer
      assert Process.alive?(worker)
      assert Longx.Repo.get!(Oban.Job, first.id).state == "executing"
      assert Longx.Repo.get!(Oban.Job, second.id).state == "available"
      :ok = Exqlite.Sqlite3.execute(lock, "ROLLBACK")
      send(producer, :dispatch)
      assert_receive {:worker_started, next}, 5_000
      assert next != worker
      send(worker, :finish)
      send(next, :finish)
    after
      :sys.resume(producer)
      Exqlite.Sqlite3.close(lock)
    end
  end

  test "non-lock SQL failures are not swallowed" do
    conf = Oban.config(@oban)
    :ok = stop_supervised(@oban)
    meta = %{queue: "busy", limit: 2, paused: false, node: "test"}
    Longx.Repo.query!("DROP TABLE oban_jobs")
    assert_raise Exqlite.Error, fn -> Longx.ObanEngine.fetch_jobs(conf, meta, %{}) end
  end
end
