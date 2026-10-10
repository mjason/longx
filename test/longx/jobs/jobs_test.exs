defmodule Longx.JobsTest do
  # Background jobs, owned by Longx and named by the agent: an agent once ran
  # twenty `nohup … &` backtests and polled their logs; the processes were
  # orphans no ledger listed, and after a compaction nobody knew their pids.
  use Longx.DataCase, async: false

  alias Longx.Jobs

  setup do
    dir = Path.join(System.tmp_dir!(), "longx-jobs-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:longx, Longx.Jobs, [])
    Application.put_env(:longx, Longx.Jobs, Keyword.put(previous, :dir, dir))
    thread = "native_jobs_#{System.unique_integer([:positive])}"
    me = self()

    on_exit(fn ->
      Jobs.delete(thread)
      Application.put_env(:longx, Longx.Jobs, previous)
      File.rm_rf!(dir)
    end)

    %{
      dir: dir,
      thread: thread,
      opts: [cwd: System.tmp_dir!(), on_exit: &send(me, {:job_exited, &1})]
    }
  end

  test "verified follow-up explicitly reconciles older failures without rerunning", %{
    thread: thread,
    opts: opts
  } do
    assert {:ok, old} = Jobs.start(thread, "old", "exit 1", opts)
    assert {:ok, _} = Jobs.wait(thread, "old", 5_000)
    assert {:ok, assessed} = Jobs.review(thread, "old", old.run, "incomplete", "failed")
    refute Jobs.awaiting_review?(assessed)
    assert {:ok, good} = Jobs.start(thread, "good", "true", opts)
    assert {:ok, _} = Jobs.wait(thread, "good", 5_000)
    assert {:ok, _} = Jobs.review(thread, "good", good.run, "complete", "verified")
    assert [{%{run: old_run}, %{run: good_run}}] = Jobs.reconciliation(thread)
    assert old_run == old.run and good_run == good.run
    step = Longx.Agent.Step.new(phase: :turn_end, thread_id: thread)
    reminded = Longx.Agent.Plugs.Jobs.call(step, [])
    assert [{:continue, text, _}] = reminded.effects
    assert text =~ "Reconcile old"
    assert text =~ "Do not rerun"
    assert Longx.Agent.Plugs.Jobs.call(%{reminded | effects: []}, []).effects == []
    assert {:ok, _} = Jobs.review(thread, "old", old.run, "incomplete", "unrelated success")
    assert Jobs.reconciliation(thread) == []

    assert {:error, :cannot_supersede_self} =
             Jobs.review(thread, "good", good.run, "complete", "verified", supersedes: [good.run])

    assert {:error, :stale_replacement} =
             Jobs.review(thread, "good", good.run, "complete", "verified",
               supersedes: ["missing"]
             )

    assert {:error, :not_successful} =
             Jobs.review(thread, "old", old.run, "complete", "failed", supersedes: [good.run])

    assert {:ok, _} =
             Jobs.review(thread, "good", good.run, "complete", "same checks now pass",
               supersedes: [old.run]
             )

    assert Jobs.pending(thread) == []
    assert Jobs.reconciliation(thread) == []
    assert Enum.find(Jobs.list(thread), &(&1.run == old.run)).superseded_by == good.run
  end

  test "replacement rejects background, running and stale targets without clearing stopped work",
       %{thread: thread, opts: opts} do
    {:ok, stopped} = Jobs.start(thread, "stopped", "sleep 30", opts)
    assert {:ok, _} = Jobs.stop(thread, "stopped")
    assert {:ok, _} = Jobs.review(thread, "stopped", stopped.run, "incomplete", "person stopped")

    {:ok, service} =
      Jobs.start(thread, "service", "true", Keyword.put(opts, :purpose, "background"))

    assert {:ok, _} = Jobs.wait(thread, "service", 5_000)
    {:ok, running} = Jobs.start(thread, "running", "sleep 30", opts)
    {:ok, good} = Jobs.start(thread, "good", "true", opts)
    assert {:ok, _} = Jobs.wait(thread, "good", 5_000)

    assert {:error, :not_required_work} =
             Jobs.review(thread, "good", good.run, "complete", "verified",
               supersedes: [service.run]
             )

    assert {:error, :still_running} =
             Jobs.review(thread, "good", good.run, "complete", "verified",
               supersedes: [running.run]
             )

    assert {:error, :stale_run} =
             Jobs.review(thread, "good", "stale", "complete", "verified",
               supersedes: [stopped.run]
             )

    assert Enum.find(Jobs.list(thread), &(&1.run == stopped.run)).review == "incomplete"
    assert Enum.find(Jobs.list(thread), &(&1.run == good.run)).review == nil

    assert {:error, :not_required_work} =
             Jobs.review(thread, "service", service.run, "complete", "verified",
               supersedes: [stopped.run]
             )

    assert {:ok, _} = Jobs.set_purpose(thread, "service", service.run, "wait")

    assert {:error, :replacement_not_earlier} =
             Jobs.review(thread, "service", service.run, "complete", "verified",
               supersedes: [good.run]
             )

    assert {:ok, _} = Jobs.stop(thread, "running")
  end

  @tag :cgroup
  test "job resource exit diagnostics survive in the saved reason and log",
       %{thread: thread, opts: opts} do
    # Feed a protocol frame, not a real OOM or leaked process.
    assert {:ok, _} = Jobs.start(thread, "resource-exit", "echo ready; sleep 30", opts)
    [{pid, _}] = Registry.lookup(Longx.Jobs.Registry, {thread, "resource-exit"})
    %{shim: shim} = :sys.get_state(pid)
    %{port: port} = :sys.get_state(shim)
    report = %{"oom_kill" => 1, "populated" => true, "cleanup_error" => "cleanup denied"}
    send(shim, {port, {:data, <<26, Jason.encode!(report)::binary>>}})
    :sys.get_state(shim)
    Longx.Shim.kill(shim, 0)
    assert {:ok, %{status: "failed", reason: reason}} = Jobs.wait(thread, "resource-exit", 5_000)
    assert reason =~ "memory limit" and reason =~ "still populated" and reason =~ "cleanup denied"
    assert {:ok, %{text: text, info: %{reason: ^reason}}} = Jobs.output(thread, "resource-exit")
    assert text =~ "cleanup denied"
    assert [%{reason: ^reason}] = Jobs.list(thread)
  end

  @tag :cgroup
  test "synthetic exit preserves an unknown code and a failed cleanup", %{
    thread: thread,
    opts: opts
  } do
    # Protocol fixture only: do not create a real kernel-stuck task.
    assert {:ok, _} = Jobs.start(thread, "unknown-exit", "sleep 30", opts)
    [{pid, _}] = Registry.lookup(Longx.Jobs.Registry, {thread, "unknown-exit"})
    %{shim: shim} = :sys.get_state(pid)
    %{port: port} = :sys.get_state(shim)
    ref = Process.monitor(shim)
    report = %{"oom_kill" => 0, "populated" => true, "cleanup_error" => "root still alive"}
    send(shim, {port, {:data, <<26, Jason.encode!(report)::binary>>}})
    send(shim, {port, {:data, <<21, -1::signed-big-32>>}})
    send(shim, {port, {:data, <<18>>}})

    assert {:ok, %{status: "failed", exit_code: -1, reason: reason}} =
             Jobs.wait(thread, "unknown-exit", 5_000)

    assert reason =~ "root still alive" and reason =~ "do not restart"
    refute reason =~ "memory limit"
    assert {:ok, %{text: text, info: %{exit_code: -1}}} = Jobs.output(thread, "unknown-exit")
    assert text =~ "root still alive"
    assert_receive {:DOWN, ^ref, :process, ^shim, _}, 5_000
  end

  @tag :cgroup
  test "jobs forward guard options and retain visible fallback in output and reason",
       %{thread: thread, opts: opts} do
    guards = [cgroup: :auto, memory_max: 1024 * 1024 * 1024, swap_max: 0]

    assert {:ok, _} =
             Jobs.start(
               thread,
               "guarded",
               "sleep 0.2; echo done",
               Keyword.put(opts, :guards, guards)
             )

    [{pid, _}] = Registry.lookup(Longx.Jobs.Registry, {thread, "guarded"})
    state = :sys.get_state(pid)
    guard = Longx.Shim.resource_guard(state.shim)
    assert guard["status"] in ["active", "unavailable"]
    assert {:ok, info} = Jobs.wait(thread, "guarded", 5_000)
    assert {:ok, %{text: text}} = Jobs.output(thread, "guarded")
    assert text =~ "done"

    if guard["status"] == "unavailable" do
      assert info.reason =~ "WARNING"
      assert info.reason =~ guard["reason"]
      assert text =~ guard["reason"]
    end

    assert [%{reason: reason}] = Jobs.list(thread)
    assert reason == info.reason
  end

  test "a job runs in the background under its name: listed, read, waited for; its end is told",
       %{thread: thread, opts: opts} do
    assert {:ok, %{name: "count", status: "running"}} =
             Jobs.start(thread, "count", "echo one; sleep 0.3; echo two; exit 3", opts)

    assert [%{name: "count", status: "running", cmd: "echo one; sleep 0.3; echo two; exit 3"}] =
             Jobs.list(thread)

    # nobody waited for it: its end is told
    assert_receive {:job_exited, %{name: "count", status: "exited", exit_code: 3, tail: tail}},
                   5_000

    assert tail =~ "two"
    assert {:ok, %{text: "one\ntwo\n", info: %{status: "exited"}}} = Jobs.output(thread, "count")
    assert [%{name: "count", status: "exited", exit_code: 3}] = Jobs.list(thread)

    # waited for: the end is seen, not told
    {:ok, _} = Jobs.start(thread, "count", "sleep 0.2; exit 0", opts)
    assert {:ok, %{status: "exited", exit_code: 0}} = Jobs.wait(thread, "count", 5_000)
    refute_receive {:job_exited, _}, 300
  end

  test "a name is one job at a time: a running one refuses another, a finished one is replaced",
       %{thread: thread, opts: opts} do
    {:ok, _} = Jobs.start(thread, "server", "sleep 5", opts)

    assert {:error, {:running, %{name: "server", cmd: "sleep 5"}}} =
             Jobs.start(thread, "server", "sleep 1", opts)

    assert {:error, :bad_name} = Jobs.start(thread, "../x", "true", opts)
    {:ok, _} = Jobs.stop(thread, "server")
    assert {:ok, %{cmd: "echo again"}} = Jobs.start(thread, "server", "echo again", opts)
    assert {:ok, %{exit_code: 0}} = Jobs.wait(thread, "server", 5_000)
  end

  test "stopping a job ends its whole tree; the agent stopped it, so its end is not told again",
       %{thread: thread, opts: opts} do
    {:ok, _} = Jobs.start(thread, "tree", "sleep 30 & echo $!; wait", opts)
    pid = eventually_pid(thread, "tree")
    assert {:ok, %{status: "stopped"}} = Jobs.stop(thread, "tree")
    assert eventually(fn -> not os_alive?(pid) end)
    refute_receive {:job_exited, _}, 300
    assert Jobs.observed?(thread, "tree", hd(Jobs.list(thread)).run)
  end

  test "a job is in the command ledger: the settings page lists it and stops it; the end says who",
       %{thread: thread, opts: opts} do
    {:ok, _} = Jobs.start(thread, "long", "sleep 30", opts)

    assert %{id: id, cmd: "[job long] sleep 30", thread_id: ^thread} =
             Enum.find(Longx.System.Commands.list(), &(&1.thread_id == thread))

    :ok = Longx.System.Commands.kill(id)

    assert_receive {:job_exited, %{name: "long", status: "killed", reason: reason}}, 5_000
    assert reason =~ "the person"
  end

  test "a job outlives whoever started it", %{thread: thread, opts: opts} do
    Task.async(fn -> Jobs.start(thread, "orphan-proof", "sleep 1; echo done", opts) end)
    |> Task.await()

    assert [%{status: "running"}] = Jobs.list(thread)
    assert {:ok, %{exit_code: 0}} = Jobs.wait(thread, "orphan-proof", 5_000)
  end

  test "a thread keeps its latest finished jobs within the limits", %{thread: thread, opts: opts} do
    for n <- 1..4 do
      {:ok, _} =
        Jobs.start(
          thread,
          "j#{n}",
          "true",
          Keyword.merge(opts, keep_finished: 2, purpose: "background")
        )

      {:ok, _} = Jobs.wait(thread, "j#{n}", 5_000)
    end

    Jobs.prune(thread, keep_finished: 2)
    assert thread |> Jobs.list() |> Enum.map(& &1.name) |> Enum.sort() == ["j3", "j4"]
  end

  test "required results remain pending after reads until explicitly reviewed", %{
    thread: thread,
    opts: opts
  } do
    {:ok, job} = Jobs.start(thread, "verify", "echo verified", Keyword.put(opts, :notify, false))
    assert job.purpose == "wait"
    assert Jobs.activity(Jobs.list(thread)).state == "waiting"
    assert {:ok, %{exit_code: 0}} = Jobs.wait(thread, "verify", 5_000)
    assert Jobs.activity(Jobs.list(thread)).state == "pending"
    assert Jobs.activity(Jobs.list(thread), true).state == "processing"
    step = Longx.Agent.Step.new(phase: :turn_end, thread_id: thread)
    reminded = Longx.Agent.Plugs.Jobs.call(step, [])
    assert [{:continue, text, %{"kind" => "job", "status" => "review"}}] = reminded.effects
    assert text =~ "review_job"
    assert Longx.Agent.Plugs.Jobs.call(%{reminded | effects: []}, []).effects == []
    assert [thread] == Jobs.pending_threads()
    Jobs.prune(thread, keep_finished: 0)
    assert [_] = Jobs.pending(thread)

    assert {:error, :stale_run} =
             Jobs.review(thread, "verify", "wrong-run", "complete", "verified")

    assert {:ok, _} = Jobs.review(thread, "verify", job.run, "complete", "output checked")
    assert Jobs.activity(Jobs.list(thread)).state == "complete"
    Jobs.prune(thread, keep_finished: 0)
    assert Jobs.list(thread) == []
  end

  test "a browser log read does not observe the result and a service is not pending work", %{
    thread: thread,
    opts: opts
  } do
    {:ok, job} =
      Jobs.start(
        thread,
        "service",
        "echo ready",
        Keyword.merge(opts, purpose: "background", notify: false)
      )

    assert Jobs.pending(thread) == []
    assert eventually(fn -> match?([%{status: "exited"}], Jobs.list(thread)) end)
    assert {:ok, %{info: %{observed: false}}} = Jobs.output(thread, "service", observe: false)
    refute Jobs.observed?(thread, "service", job.run)
  end

  test "failed and stopped work cannot be acknowledged as successful", %{
    thread: thread,
    opts: opts
  } do
    {:ok, failed} = Jobs.start(thread, "failure", "exit 2", Keyword.put(opts, :notify, false))
    assert {:ok, %{exit_code: 2}} = Jobs.wait(thread, "failure", 5_000)
    assert Jobs.activity(Jobs.list(thread)).state == "incomplete"

    assert {:error, :not_successful} =
             Jobs.review(thread, "failure", failed.run, "complete", "pretend")

    assert {:ok, _} = Jobs.review(thread, "failure", failed.run, "incomplete", "needs repair")
    assert [_] = Jobs.pending(thread)

    assert {:ok, _} =
             Jobs.review(thread, "failure", failed.run, "superseded", "verified replacement")

    {:ok, stopped} = Jobs.start(thread, "stopped", "sleep 30", Keyword.put(opts, :notify, false))

    assert {:ok, %{status: "stopped"}} =
             Jobs.stop(thread, "stopped", run: stopped.run, by: :person)

    assert Jobs.activity(Jobs.list(thread)).state == "incomplete"
  end

  test "purpose changes and stops target the exact run", %{thread: thread, opts: opts} do
    {:ok, job} = Jobs.start(thread, "changing", "sleep 30", opts)
    assert {:error, :stale_run} = Jobs.set_purpose(thread, "changing", "old", "background")
    assert {:error, :stale_run} = Jobs.stop(thread, "changing", run: "old", by: :person)

    assert {:ok, %{purpose: "background"}} =
             Jobs.set_purpose(thread, "changing", job.run, "background")

    assert Jobs.pending(thread) == []
    assert {:ok, %{purpose: "wait"}} = Jobs.set_purpose(thread, "changing", job.run, "wait")
    assert [_] = Jobs.pending(thread)
    assert {:ok, _} = Jobs.stop(thread, "changing")
  end

  test "a required job lost on restart remains incomplete", %{dir: dir, thread: thread} do
    job_dir = Path.join([dir, thread, "lost-required"])
    File.mkdir_p!(job_dir)

    File.write!(
      Path.join(job_dir, "job.json"),
      Jason.encode!(%{
        name: "lost-required",
        cmd: "sleep 30",
        status: "running",
        run: "r1",
        purpose: "wait"
      })
    )

    assert Jobs.settle_after_restart() == 1
    assert Jobs.activity(Jobs.list(thread)).state == "incomplete"
    assert [thread] == Jobs.pending_threads()
  end

  test "after a restart a job that was running is lost, and says so", %{dir: dir, thread: thread} do
    job_dir = Path.join([dir, thread, "gone"])
    File.mkdir_p!(job_dir)

    File.write!(
      Path.join(job_dir, "job.json"),
      Jason.encode!(%{name: "gone", cmd: "sleep 100", status: "running", run: "r1"})
    )

    assert Jobs.settle_after_restart() == 1
    assert [%{name: "gone", status: "lost", reason: reason}] = Jobs.list(thread)
    assert reason =~ "restarted"
  end

  test "deleting a thread's jobs stops them and removes their logs", %{
    dir: dir,
    thread: thread,
    opts: opts
  } do
    {:ok, _} = Jobs.start(thread, "a", "sleep 30", opts)
    :ok = Jobs.delete(thread)
    assert Jobs.list(thread) == []
    refute File.exists?(Path.join(dir, thread))
  end

  defp eventually_pid(thread, name) do
    assert eventually(fn -> match?({:ok, %{text: "" <> _}}, Jobs.output(thread, name)) end)

    eventually_value(fn ->
      with {:ok, %{text: text}} <- Jobs.output(thread, name),
           {pid, _} <- Integer.parse(String.trim(text)),
           do: pid,
           else: (_ -> nil)
    end)
  end

  defp eventually_value(fun, tries \\ 100) do
    case fun.() do
      nil when tries > 0 ->
        receive do
        after
          20 -> eventually_value(fun, tries - 1)
        end

      value ->
        value
    end
  end

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        receive do
        after
          20 -> eventually(fun, tries - 1)
        end
    end
  end

  defp os_alive?(pid),
    do: match?({_, 0}, System.cmd("kill", ["-0", "#{pid}"], stderr_to_stdout: true))
end
