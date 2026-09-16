defmodule Longx.Projects.ResilienceTest do
  @moduledoc """
  What happens to project threads and turns when their codex dies, comes
  back, or stops making progress. Uses the per-project pool with the fake
  app-server (no `conn:` passed: the pool is the default).
  """
  use Longx.DataCase, async: false

  alias Longx.Codex.Pool
  alias Longx.Projects
  alias Longx.Projects.{Thread, Turn}

  setup do
    Ash.bulk_destroy!(Turn, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(Thread, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(Projects.Project, :destroy, %{}, authorize?: false)

    dir = Path.join(System.tmp_dir!(), "longx-res-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    project =
      Projects.create_project!(%{name: "R #{System.unique_integer([:positive])}", root_path: dir})

    Phoenix.PubSub.subscribe(Longx.PubSub, "codex:connection")

    on_exit(fn ->
      Longx.Test.PoolHelpers.stop_pool!([project.id])
      File.rm_rf!(dir)
    end)

    %{project: project}
  end

  defp eventually(fun, attempts \\ 100) do
    case fun.() do
      {:ok, value} ->
        value

      _ when attempts > 0 ->
        Process.sleep(50)
        eventually(fun, attempts - 1)

      other ->
        flunk("condition not met: #{inspect(other)}")
    end
  end

  defp turn_status(turn_id, wanted) do
    fn ->
      case Ash.get!(Turn, turn_id) do
        %{status: ^wanted} = turn -> {:ok, turn}
        other -> {:pending, other.status}
      end
    end
  end

  defp thread_status(thread_id, wanted) do
    fn ->
      case Ash.get!(Thread, thread_id) do
        %{status: ^wanted} = thread -> {:ok, thread}
        other -> {:pending, other.status}
      end
    end
  end

  test "without conn: the project's pooled codex is used", %{project: project} do
    {:ok, thread} = Projects.start_thread(project)
    project_id = project.id
    assert_receive {:codex_connection, ^project_id, :ready}, 15_000
    {:ok, turn} = Projects.send_message(thread, "say hi")
    assert %{status: :completed} = eventually(turn_status(turn.id, :completed))
    assert project_id in Pool.running()
  end

  test "the project's codex watches the root for us once it is up: a change it reports reaches the project channel",
       %{project: project} do
    project_id = project.id
    Phoenix.PubSub.subscribe(Longx.PubSub, "project:" <> project_id)
    {:ok, thread} = Projects.start_thread(project)
    assert_receive {:codex_connection, ^project_id, :ready}, 15_000
    {:ok, conn} = Pool.connection(project_id)

    watched =
      eventually(fn ->
        {:ok, %{"thread" => %{"watches" => watches}}} =
          Longx.Codex.Connection.request(conn, "thread/read", %{
            "threadId" => thread.codex_thread_id
          })

        if map_size(watches) > 0, do: {:ok, watches}, else: :pending
      end)

    assert watched == %{project_id => project.root_path}

    changed = Path.join(project.root_path, "a.txt")
    {:ok, turn} = Projects.send_message(thread, "touch " <> changed)
    eventually(turn_status(turn.id, :completed))
    assert_receive {:files_changed, ^project_id, [^changed]}, 5_000
  end

  test "codex_info says when the running codex booted with settings that have since changed", %{
    project: project
  } do
    assert Projects.codex_info(project).stale == []

    {:ok, _thread} = Projects.start_thread(project)
    project_id = project.id
    assert_receive {:codex_connection, ^project_id, :ready}, 15_000
    assert Projects.codex_info(project).stale == []

    # a model's window is edited: the catalog this codex read is behind
    {:ok, model} = Longx.AI.default_model()
    Longx.AI.update_model!(model, %{context_window: model.context_window + 1})
    assert Projects.codex_info(project).stale == [:models]

    # a restart writes the home afresh
    {:ok, _} = Projects.restart_codex(project)
    assert_receive {:codex_connection, ^project_id, :ready}, 15_000
    assert Projects.codex_info(project).stale == []

    # host paths let into the sandbox are read by the exec-server at every
    # command: a change is not a restart
    {:ok, project} = Projects.update_project(project, %{passthrough_paths: ["/dev/null"]})
    assert Projects.codex_info(project).stale == []
    assert "/dev/null" in Projects.exec_context(project.id).sandbox[:passthrough]
  end

  test "Longx restarted (the Tracker forgot every thread): the next message on a thread follows it again, so its turn still completes",
       %{project: project} do
    project_id = project.id
    {:ok, thread} = Projects.start_thread(project)
    assert_receive {:codex_connection, ^project_id, :ready}, 15_000

    # what a BEAM restart leaves: a fresh Tracker with nothing tracked
    pid = Process.whereis(Longx.Projects.Tracker)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}, 5_000

    eventually(fn ->
      if Process.whereis(Longx.Projects.Tracker), do: {:ok, :up}, else: :pending
    end)

    {:ok, turn} = Projects.send_message(thread, "say hello again")
    assert %{status: :completed} = eventually(turn_status(turn.id, :completed))
    assert %{status: :idle} = eventually(thread_status(thread.id, :idle))
  end

  test "settle_after_restart/0: turns and threads a previous boot left running are closed — no codex survives the BEAM",
       %{project: project} do
    {:ok, thread} = Projects.start_thread(project)
    Projects.touch_thread!(thread, %{status: :active})

    {:ok, turn} =
      Projects.create_turn(%{
        codex_turn_id: "turn_from_last_boot",
        thread_id: thread.id,
        user_text: "left running",
        started_at: DateTime.utc_now()
      })

    assert %{turns: 1, threads: 1} = Projects.settle_after_restart()
    assert %{status: :failed, error: error, completed_at: %DateTime{}} = Ash.get!(Turn, turn.id)
    assert error =~ "Longx restarted"
    assert Ash.get!(Thread, thread.id).status == :idle
    assert %{turns: 0, threads: 0} = Projects.settle_after_restart()
  end

  test "codex dies mid-turn: the turn fails, the thread is disconnected, then resumed when codex is back",
       %{project: project} do
    project_id = project.id
    {:ok, thread} = Projects.start_thread(project)
    assert_receive {:codex_connection, ^project_id, :ready}, 15_000

    # a turn is running when the fake is told to exit
    :ok = Phoenix.PubSub.subscribe(Longx.PubSub, Longx.Notify.topic())
    {:ok, running} = Projects.send_message(thread, "stall")
    _ = Projects.send_message(thread, "die")
    assert_receive {:codex_connection, ^project_id, :down}, 5_000

    failed = eventually(turn_status(running.id, :failed))
    assert failed.error =~ "codex"
    assert %DateTime{} = failed.completed_at

    # the notify feed hears of it, pointing at the thread
    url = "/p/#{project.slug}/t/#{thread.id}"
    assert_receive {:notify, %{kind: "turn_failed", url: ^url, body: body}}, 5_000
    assert body =~ "codex"

    # the worker restarts on its own; the thread is resumed there
    assert_receive {:codex_connection, ^project_id, :ready}, 15_000
    idle = eventually(thread_status(thread.id, :idle))
    assert idle.status == :idle

    # resumed with the model's current settings (context window, web search), like a start
    {:ok, conn} = Pool.connection_for_thread(thread.codex_thread_id)

    assert {:ok, %{"thread" => %{"resumeParams" => %{"config" => config}}}} =
             Longx.Codex.Connection.request(conn, "thread/read", %{
               "threadId" => thread.codex_thread_id
             })

    assert config["model_context_window"] == Longx.AI.default_model!().context_window
    assert config["features.multi_agent_v2"] == true
    assert config["approvals_reviewer"] == "auto_review"

    # and it keeps working on the new process
    {:ok, turn} = Projects.send_message(thread, "say again")
    assert %{status: :completed} = eventually(turn_status(turn.id, :completed))
  end

  test "a thread that cannot be resumed is marked unrecoverable and refuses new messages",
       %{project: project} do
    project_id = project.id
    {:ok, thread} = Projects.start_thread(project)
    assert_receive {:codex_connection, ^project_id, :ready}, 15_000
    # the fake forgets threads when it dies; a thread it never saw cannot be resumed
    Projects.touch_thread!(thread, %{status: :active})

    Ash.update!(
      Ash.Changeset.for_update(thread, :touch, %{})
      |> Ash.Changeset.force_change_attribute(:codex_thread_id, "thr_never_existed")
    )

    :ok = Projects.stop_codex(project, force: true)
    assert_receive {:codex_connection, ^project_id, :down}, 5_000
    assert %{status: :disconnected} = Ash.get!(Thread, thread.id)

    {:ok, _} = Pool.connection(project_id)
    assert_receive {:codex_connection, ^project_id, :ready}, 15_000
    unrecoverable = eventually(thread_status(thread.id, :unrecoverable))
    assert {:error, :thread_unrecoverable} = Projects.send_message(unrecoverable, "say x")
  end

  test "a turn with no progress is interrupted (stall timeout)", %{project: project} do
    old = Application.get_env(:longx, Longx.Projects.Tracker, [])
    Application.put_env(:longx, Longx.Projects.Tracker, stall_after: 300, tick: 100)
    on_exit(fn -> Application.put_env(:longx, Longx.Projects.Tracker, old) end)

    project_id = project.id
    {:ok, thread} = Projects.start_thread(project)
    assert_receive {:codex_connection, ^project_id, :ready}, 15_000

    {:ok, turn} = Projects.send_message(thread, "stall")
    done = eventually(turn_status(turn.id, :interrupted))
    assert done.error =~ "no progress"
    # the thread row is written right after the turn's: poll it too
    assert %{status: :idle} = eventually(thread_status(thread.id, :idle))
  end

  describe "sub-agents" do
    test "a spawned sub-agent becomes a thread row under its parent, hidden from the project's list; its view is live",
         %{project: project} do
      {:ok, parent} = Projects.start_thread(project)
      {:ok, turn} = Projects.send_message(parent, "spawn helper")
      eventually(turn_status(turn.id, :completed))

      child =
        eventually(fn ->
          case Projects.list_subagents!(parent.id) do
            [child] -> {:ok, child}
            other -> {:pending, other}
          end
        end)

      assert child.parent_thread_id == parent.id
      assert child.codex_thread_id == parent.codex_thread_id <> "-helper"
      assert child.agent_path == "/root/helper"
      assert child.title == "helper"
      assert child.project_id == project.id
      assert child.cwd == parent.cwd
      eventually(thread_status(child.id, :idle))

      # not in the project's thread list
      refute Enum.any?(Projects.list_threads!(project), &(&1.id == child.id))

      # its codex view is there (items on its own thread id), and so is the parent's plan
      snap = Longx.Codex.Thread.snapshot(child.codex_thread_id)

      assert Enum.any?(
               snap.items,
               &(&1["type"] == "agentMessage" and &1["text"] == "done by helper")
             )

      assert %{plan: %{"plan" => [_, _, %{"step" => "report"}]}} =
               Longx.Codex.Thread.snapshot(parent.codex_thread_id)
    end
  end
end
