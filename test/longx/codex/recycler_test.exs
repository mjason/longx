defmodule Longx.Codex.RecyclerTest do
  # Idle codex processes past their thresholds are stopped (the next use
  # starts a fresh one); busy ones are left alone. Fake app-server via the pool.
  use Longx.DataCase, async: false

  alias Longx.Codex.{Pool, Recycler, Thread}

  setup do
    Phoenix.PubSub.subscribe(Longx.PubSub, "codex:connection")
    a = Ash.UUID.generate()
    old = Application.get_env(:longx, Recycler, [])

    on_exit(fn ->
      Application.put_env(:longx, Recycler, old)
      Longx.Test.PoolHelpers.stop_pool!([a])
    end)

    %{a: a, old: old}
  end

  defp configure(opts), do: Application.put_env(:longx, Recycler, opts)

  defp ready!(a) do
    {:ok, conn} = Pool.connection(a)
    assert_receive {:codex_connection, ^a, :ready}, 15_000
    conn
  end

  test "an idle worker over max_turns is stopped on the next sweep", %{a: a} do
    configure(max_turns: 1)
    conn = ready!(a)
    {:ok, thread_id} = Thread.start(cwd: "/", tools: [], conn: conn)
    Thread.subscribe(thread_id)
    {:ok, _} = Thread.send(thread_id, "say hi", conn: conn)
    assert_receive {:codex, _, "turn/completed", _}, 10_000

    assert [{^a, :recycled, :max_turns}] = Recycler.sweep()
    assert_receive {:codex_connection, ^a, :down}, 10_000
    assert Pool.status(a) == :stopped
  end

  test "a worker with a turn in flight is never recycled", %{a: a} do
    configure(max_turns: 1, max_uptime_ms: 1)
    conn = ready!(a)
    {:ok, thread_id} = Thread.start(cwd: "/", tools: [], conn: conn)
    Thread.subscribe(thread_id)
    {:ok, turn_id} = Thread.send(thread_id, "stall", conn: conn)
    assert_receive {:codex, _, "item/agentMessage/delta", _}, 10_000

    assert [{^a, :busy, _}] = Recycler.sweep()
    assert %{pid: ^conn} = Pool.status(a)

    :ok = Thread.interrupt(thread_id, turn_id, conn: conn)
    assert_receive {:codex, _, "turn/completed", _}, 10_000
  end

  test "uptime and memory thresholds", %{a: a} do
    configure(max_uptime_ms: 1)
    ready!(a)
    assert [{^a, :recycled, :max_uptime}] = Recycler.sweep()
    assert_receive {:codex_connection, ^a, :down}, 10_000

    configure(max_rss_bytes: 1)
    ready!(a)
    assert [{^a, :recycled, :max_rss}] = Recycler.sweep()
    assert_receive {:codex_connection, ^a, :down}, 10_000
  end

  test "a healthy worker is kept and its numbers are published as telemetry", %{a: a} do
    configure([])
    ready!(a)
    test_pid = self()
    handler = "recycler-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:longx, :codex, :worker, :sample],
      fn _event, measurements, metadata, _ ->
        send(test_pid, {:sample, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert [{^a, :kept, _}] = Recycler.sweep()

    assert_receive {:sample, %{rss_bytes: rss, processes: _, cpu_ms: _, uptime_ms: _, turns: 0},
                    %{project_id: ^a}}

    assert rss > 0
    assert %{pid: _} = Pool.status(a)
  end
end
