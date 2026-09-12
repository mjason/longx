defmodule Longx.Codex.PoolTest do
  # One codex process per project: lazily started, independently restarted,
  # stoppable. Runs against the fake app-server (config/test.exs).
  # DataCase: the Tracker reacts to every worker's :down/:ready in the DB
  use Longx.DataCase, async: false

  alias Longx.Codex.{Connection, Pool, Thread}

  setup do
    Phoenix.PubSub.subscribe(Longx.PubSub, "codex:connection")
    # project ids are uuids: the tracker looks them up on :down / :ready
    a = Ash.UUID.generate()
    b = Ash.UUID.generate()
    on_exit(fn -> Longx.Test.PoolHelpers.stop_pool!([a, b]) end)
    %{a: a, b: b}
  end

  defp crash!(conn) do
    {:ok, thread_id} = Thread.start(cwd: "/", tools: [], conn: conn)
    # the fake exits on this turn; the request fails as the connection resets
    {:error, :connection_reset} = Thread.send(thread_id, "die", conn: conn)
    :ok
  end

  test "connection/1 starts a worker per project on first use and reuses it", %{a: a, b: b} do
    assert Pool.status(a) == :stopped

    assert {:ok, conn_a} = Pool.connection(a)
    assert_receive {:codex_connection, ^a, :ready}, 15_000
    assert {:ok, ^conn_a} = Pool.connection(a)
    assert %{pid: ^conn_a, phase: :ready} = Pool.status(a)

    assert {:ok, conn_b} = Pool.connection(b)
    assert_receive {:codex_connection, ^b, :ready}, 15_000
    refute conn_b == conn_a

    assert a in Pool.running()
    assert b in Pool.running()
  end

  test "a crash in one project restarts only that project's codex", %{a: a, b: b} do
    {:ok, conn_a} = Pool.connection(a)
    {:ok, conn_b} = Pool.connection(b)
    assert_receive {:codex_connection, ^a, :ready}, 15_000
    assert_receive {:codex_connection, ^b, :ready}, 15_000

    crash!(conn_a)

    assert_receive {:codex_connection, ^a, :down}, 5_000
    assert_receive {:codex_connection, ^a, :ready}, 15_000
    refute_received {:codex_connection, ^b, :down}

    assert {:ok, new_a} = Pool.connection(a)
    refute new_a == conn_a
    assert {:ok, ^conn_b} = Pool.connection(b)
    assert Connection.status(conn_b) == :ready
  end

  test "an exhausted restart budget stops that project only; the next call starts it afresh",
       %{a: a, b: b} do
    {:ok, _} = Pool.connection(b)
    assert_receive {:codex_connection, ^b, :ready}, 15_000

    for _ <- 1..4 do
      {:ok, conn} = Pool.connection(a)
      assert_receive {:codex_connection, ^a, :ready}, 15_000
      crash!(conn)
      assert_receive {:codex_connection, ^a, :down}, 5_000
    end

    # budget (3 restarts / 60 s) gone: the worker is dead, not crash-looping
    wait_until(fn -> Pool.status(a) == :stopped end)
    refute_received {:codex_connection, ^b, :down}

    assert {:ok, _} = Pool.connection(a)
    assert_receive {:codex_connection, ^a, :ready}, 15_000
  end

  test "stop/2 and restart/1", %{a: a} do
    {:ok, conn} = Pool.connection(a)
    assert_receive {:codex_connection, ^a, :ready}, 15_000
    ref = Process.monitor(conn)

    assert :ok = Pool.stop(a)
    assert_receive {:DOWN, ^ref, :process, ^conn, _}, 10_000
    assert Pool.status(a) == :stopped
    assert :ok = Pool.stop(a)

    assert {:ok, again} = Pool.connection(a)
    assert_receive {:codex_connection, ^a, :ready}, 15_000
    assert {:ok, restarted} = Pool.restart(a)
    refute restarted == again
    assert_receive {:codex_connection, ^a, :ready}, 15_000
  end

  test "threads know their connection, so Thread calls need no conn: after the start", %{a: a} do
    {:ok, conn} = Pool.connection(a)
    assert_receive {:codex_connection, ^a, :ready}, 15_000

    {:ok, thread_id} = Thread.start(cwd: "/", tools: [], conn: conn)
    Thread.subscribe(thread_id)
    assert_receive {:codex, _, "thread/started", _}, 5_000

    assert {:ok, ^conn} = Pool.connection_for_thread(thread_id)
    assert {:ok, _turn} = Thread.send(thread_id, "say hi")
    assert_receive {:codex, _, "turn/completed", _}, 10_000

    assert {:error, :no_connection} = Pool.connection_for_thread("thr_nobody")
    assert {:error, :no_connection} = Thread.send("thr_nobody", "say hi")
  end

  test "status/1 reports the process tree and turn counters", %{a: a} do
    {:ok, conn} = Pool.connection(a)
    assert_receive {:codex_connection, ^a, :ready}, 15_000

    info = Pool.status(a)
    assert %{stats: %{processes: n, rss_bytes: rss, cpu_ms: _}} = info
    assert n >= 1 and rss > 0
    assert info.turns == 0
    assert info.active_turns == 0
    assert info.memory_limit == nil

    {:ok, thread_id} = Thread.start(cwd: "/", tools: [], conn: conn)
    Thread.subscribe(thread_id)
    {:ok, _} = Thread.send(thread_id, "say hi", conn: conn)
    assert_receive {:codex, _, "turn/completed", _}, 10_000

    assert %{turns: 1, active_turns: 0} = Pool.status(a)
  end

  test "connection/2 passes shim options (a memory cap) to the worker", %{a: a} do
    # RLIMIT_AS counts address space: the fake is a BEAM, which reserves 1 GiB up front
    {:ok, _} = Pool.connection(a, shim: [memory_limit: 16 * 1024 * 1024 * 1024])
    assert_receive {:codex_connection, ^a, :ready}, 15_000
    assert %{memory_limit: 17_179_869_184} = Pool.status(a)
  end

  test "home_dir/1 is a per-project directory under the configured codex home", %{a: a} do
    assert Pool.home_dir(a) == Path.join(Longx.Codex.Home.default_dir(), a)
  end

  defp wait_until(fun, attempts \\ 50) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not met")
      true -> Process.sleep(100) && wait_until(fun, attempts - 1)
    end
  end
end
