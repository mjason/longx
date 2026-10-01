defmodule Longx.BootRecoveryTest do
  # LONX-M: the Tracker used to start before the asynchronous boot cleanup.
  # It reported an ordinary restart as a crash, and cleanup could then fail
  # a new turn. Exercise the application's actual ordering, not a test-only one.
  use Longx.DataCase, async: false

  alias Longx.{Jobs, Projects, Watches}
  alias Longx.Projects.{Thread, Tracker, Turn}

  setup do
    Ash.bulk_destroy!(Watches.Watch, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(Turn, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(Thread, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(Projects.Project, :destroy, %{}, authorize?: false)

    dir = Path.join(System.tmp_dir!(), "longx-boot-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    previous_jobs = Application.get_env(:longx, Jobs, [])
    Application.put_env(:longx, Jobs, Keyword.put(previous_jobs, :dir, Path.join(dir, "jobs")))

    project = Projects.create_project!(%{name: "Boot recovery", root_path: dir})

    thread =
      Projects.create_thread!(%{
        project_id: project.id,
        kernel_thread_id: "native_boot_#{Ash.UUID.generate()}",
        cwd: dir,
        status: :active
      })

    turn =
      Projects.create_turn!(%{
        thread_id: thread.id,
        kernel_turn_id: "turn_boot_#{Ash.UUID.generate()}",
        user_text: "work from the previous boot",
        started_at: DateTime.utc_now()
      })

    watch =
      Watches.create_watch!(%{
        project_id: project.id,
        name: "boot-test",
        path: Path.join(dir, "boot-test.exs"),
        layer: :local,
        kind: :cron,
        cron: "*/5 * * * *"
      })
      |> Watches.mark_running()
      |> elem(1)

    job_dir = Path.join([dir, "jobs", thread.kernel_thread_id, "old-job"])
    File.mkdir_p!(job_dir)

    File.write!(
      Path.join(job_dir, "job.json"),
      Jason.encode!(%{name: "old-job", cmd: "old work", status: "running", run: "old"})
    )

    bypass = Bypass.open()
    me = self()

    Bypass.stub(bypass, "POST", "/api/7/envelope/", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(me, {:envelope, body})
      Plug.Conn.resp(conn, 200, ~s({"id":"evt"}))
    end)

    {:ok, _} = Longx.Sentry.set_dsn("http://public@localhost:#{bypass.port}/7")

    on_exit(fn ->
      Longx.Sentry.set_dsn("")
      Application.put_env(:longx, Jobs, previous_jobs)
      File.rm_rf!(dir)
    end)

    %{thread: thread, turn: turn, watch: watch}
  end

  test "boot settles old turns, watches and jobs before Tracker, Oban and the endpoint start",
       %{thread: thread, turn: turn, watch: watch} do
    me = self()

    children =
      Longx.Application.children()
      |> Enum.map(&Supervisor.child_spec(&1, []))
      |> Enum.filter(
        &(&1.id in [Longx.BootRecovery, :settle_after_restart, Tracker, Oban, LongxWeb.Endpoint])
      )
      |> Enum.map(fn
        %{id: id} when id in [Tracker, Oban, LongxWeb.Endpoint] ->
          Supervisor.child_spec(
            {Agent,
             fn ->
               send(
                 me,
                 {:starting, id, Ash.get!(Turn, turn.id), Ash.get!(Thread, thread.id),
                  Ash.get!(Watches.Watch, watch.id), Jobs.list(thread.kernel_thread_id)}
               )

               if id == Tracker, do: Tracker.handle_continue(:recover, %Tracker.State{})
               nil
             end},
            id: id
          )

        spec ->
          spec
      end)

    start_supervised!(%{
      id: :boot_sequence,
      start: {Supervisor, :start_link, [children, [strategy: :one_for_one]]},
      type: :supervisor
    })

    for id <- [Tracker, Oban, LongxWeb.Endpoint] do
      assert_receive {:starting, ^id, old_turn, old_thread, old_watch, [old_job]}, 5_000
      assert old_turn.status == :failed
      assert old_turn.error == "Longx restarted while this turn was running"
      assert old_thread.status == :idle
      assert old_watch.running_since == nil
      assert old_job.status == "lost"
    end

    refute_reported(turn.kernel_turn_id)
  end

  test "the boot cleanup is a synchronous one-shot child, not a background task" do
    children = Enum.map(Longx.Application.children(), &Supervisor.child_spec(&1, []))
    recovery = Enum.find(children, &(&1.id == Longx.BootRecovery))
    assert recovery
    assert recovery.restart == :temporary

    assert apply(elem(recovery.start, 0), elem(recovery.start, 1), elem(recovery.start, 2)) ==
             :ignore

    refute Enum.any?(children, &(&1.id == :settle_after_restart))
  end

  test "a failed completion replay after boot keeps the restart reason without reporting it again",
       %{thread: thread, turn: turn} do
    Projects.settle_after_restart()
    :ok = Tracker.track(thread.kernel_thread_id)

    send(
      Process.whereis(Tracker),
      {:thread, 1, "turn/completed",
       %{
         "threadId" => thread.kernel_thread_id,
         "turn" => %{
           "id" => turn.kernel_turn_id,
           "status" => "failed",
           "error" => %{"message" => "the agent crashed mid-turn and was restarted"}
         }
       }}
    )

    # The call is behind the replay in the same mailbox.
    Tracker.in_flight()
    assert Ash.get!(Turn, turn.id).error == "Longx restarted while this turn was running"
    refute_reported(turn.kernel_turn_id)
  end

  test "Tracker recovery after a runtime crash still reports an orphaned turn", %{turn: turn} do
    assert {:noreply, _} = Tracker.handle_continue(:recover, %Tracker.State{})
    assert Ash.get!(Turn, turn.id).status == :failed
    assert_reported(turn.kernel_turn_id)
    # Let the local envelope request finish before Bypass is stopped.
    refute_reported("a-report-that-must-not-exist")
  end

  test "a newly failed turn completion still reaches Sentry", %{thread: thread, turn: turn} do
    :ok = Tracker.track(thread.kernel_thread_id)

    send(
      Process.whereis(Tracker),
      {:thread, 1, "turn/completed",
       %{
         "threadId" => thread.kernel_thread_id,
         "turn" => %{
           "id" => turn.kernel_turn_id,
           "status" => "failed",
           "error" => %{"message" => "the tool crashed: an actual bug"}
         }
       }}
    )

    Tracker.in_flight()
    assert Ash.get!(Turn, turn.id).status == :failed
    assert_reported(turn.kernel_turn_id)
    refute_reported("a-report-that-must-not-exist")
  end

  defp refute_reported(turn_id, deadline \\ System.monotonic_time(:millisecond) + 300) do
    receive do
      {:envelope, body} ->
        refute body =~ turn_id
        refute_reported(turn_id, deadline)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> :ok
    end
  end

  defp assert_reported(turn_id, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    receive do
      {:envelope, body} ->
        if body =~ turn_id, do: :ok, else: assert_reported(turn_id, deadline)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        flunk("no Sentry report for #{turn_id}")
    end
  end
end
