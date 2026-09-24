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
      {:ok, _} = Jobs.start(thread, "j#{n}", "true", Keyword.put(opts, :keep_finished, 2))
      {:ok, _} = Jobs.wait(thread, "j#{n}", 5_000)
    end

    Jobs.prune(thread, keep_finished: 2)
    assert thread |> Jobs.list() |> Enum.map(& &1.name) |> Enum.sort() == ["j3", "j4"]
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
