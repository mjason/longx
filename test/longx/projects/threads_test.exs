defmodule Longx.Projects.ThreadsTest do
  use Longx.DataCase, async: false

  alias Longx.Codex.Connection
  alias Longx.Git
  alias Longx.Projects
  alias Longx.Projects.{Thread, Turn}

  @fake Path.expand("test/support/fake_app_server.exs")

  setup do
    Ash.bulk_destroy!(Turn, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(Thread, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(Projects.Project, :destroy, %{}, authorize?: false)

    dir = Path.join(System.tmp_dir!(), "longx-pt-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    conn = start_supervised!({Connection, name: nil, command: ["elixir", @fake], env: []})
    %{dir: dir, conn: conn}
  end

  defp git_project!(dir, attrs \\ %{}) do
    :ok = Git.init(dir)
    File.write!(Path.join(dir, "a.txt"), "v1\n")
    {:ok, _} = Git.commit_all(dir, "base")

    Projects.create_project!(
      Map.merge(%{name: "P #{System.unique_integer([:positive])}", root_path: dir}, attrs)
    )
  end

  defp plain_project!(dir),
    do:
      Projects.create_project!(%{
        name: "Plain #{System.unique_integer([:positive])}",
        root_path: dir
      })

  defp eventually(fun, attempts \\ 100) do
    case fun.() do
      {:ok, value} -> value
      _ when attempts > 0 -> Process.sleep(30) && eventually(fun, attempts - 1)
      other -> flunk("condition not met: #{inspect(other)}")
    end
  end

  defp turn_done(turn_id) do
    fn ->
      case Ash.get!(Turn, turn_id) do
        %{status: :in_progress} -> :pending
        turn -> {:ok, turn}
      end
    end
  end

  describe "start_thread/2" do
    test "starts a codex thread with the project's defaults and records it", %{
      dir: dir,
      conn: conn
    } do
      project =
        git_project!(dir, %{approval_policy: :never, sandbox: :read_only, tools: ["builtin.echo"]})

      assert {:ok, %Thread{} = thread} = Projects.start_thread(project, conn: conn)
      assert thread.codex_thread_id =~ ~r/^thr_/
      assert thread.project_id == project.id
      assert thread.cwd == project.root_path
      assert thread.approval_policy == :never
      assert thread.sandbox == :read_only
      assert thread.tools == ["builtin.echo"]
      assert thread.model_slug == nil
      assert thread.status == :idle
      assert [%{id: id}] = Projects.list_threads!(project)
      assert id == thread.id
    end

    test "per-thread overrides win over project defaults", %{dir: dir, conn: conn} do
      project = git_project!(dir)

      {:ok, thread} =
        Projects.start_thread(project,
          conn: conn,
          sandbox: :danger_full_access,
          tools: [],
          model: "deepseek-flash"
        )

      assert thread.sandbox == :danger_full_access
      assert thread.tools == []
      assert thread.model_slug == "deepseek-flash"
    end
  end

  describe "send_message/3 and the turn's git bookmarks" do
    test "clean git tree: the turn starts from HEAD and completes with the tracker filling it in",
         %{dir: dir, conn: conn} do
      project = git_project!(dir)
      {:ok, head} = Git.head(dir)
      {:ok, thread} = Projects.start_thread(project, conn: conn)

      assert {:ok, %Turn{} = turn} = Projects.send_message(thread, "say hello there", conn: conn)
      assert turn.codex_turn_id =~ ~r/^turn_/
      assert turn.user_text == "say hello there"
      assert turn.status == :in_progress
      assert turn.commit_before == head
      refute turn.dirty_start
      assert %DateTime{} = turn.started_at

      done = eventually(turn_done(turn.id))
      assert done.status == :completed
      assert %DateTime{} = done.completed_at
      assert done.commit_after == head

      thread = Ash.get!(Thread, thread.id)
      assert thread.preview == "say hello there"
      assert %DateTime{} = thread.last_activity_at
      assert thread.status == :idle
    end

    test "dirty tree with dirty_start: :commit commits first so the turn starts from a commit", %{
      dir: dir,
      conn: conn
    } do
      project = git_project!(dir, %{dirty_start: :commit})
      {:ok, before} = Git.head(dir)
      File.write!(Path.join(dir, "a.txt"), "edited by hand\n")
      {:ok, thread} = Projects.start_thread(project, conn: conn)

      {:ok, turn} = Projects.send_message(thread, "say ok", conn: conn)
      refute turn.commit_before == before
      refute turn.dirty_start
      assert %{clean?: true} = Git.status(dir)
      assert [%{sha: sha, subject: subject} | _] = Git.log(dir, limit: 1)
      assert sha == turn.commit_before
      assert subject =~ "longx: before turn"
      assert subject =~ "say ok"
    end

    test "dirty tree with dirty_start: :off only records that the start was dirty", %{
      dir: dir,
      conn: conn
    } do
      project = git_project!(dir, %{dirty_start: :off})
      {:ok, before} = Git.head(dir)
      File.write!(Path.join(dir, "a.txt"), "edited\n")
      {:ok, thread} = Projects.start_thread(project, conn: conn)

      {:ok, turn} = Projects.send_message(thread, "say ok", conn: conn)
      assert turn.commit_before == before
      assert turn.dirty_start
      assert %{clean?: false} = Git.status(dir)
    end

    test "dirty tree with dirty_start: :ask refuses until told what to do", %{
      dir: dir,
      conn: conn
    } do
      project = git_project!(dir, %{dirty_start: :ask})
      File.write!(Path.join(dir, "a.txt"), "edited\n")
      {:ok, thread} = Projects.start_thread(project, conn: conn)

      assert {:error, {:dirty_tree, [%{path: "a.txt", status: :modified}]}} =
               Projects.send_message(thread, "say ok", conn: conn)

      assert {:ok, %Turn{dirty_start: false}} =
               Projects.send_message(thread, "say ok", conn: conn, dirty: :commit)
    end

    test "a project without git still works, with no bookmarks", %{dir: dir, conn: conn} do
      project = plain_project!(dir)
      {:ok, thread} = Projects.start_thread(project, conn: conn)
      {:ok, turn} = Projects.send_message(thread, "say fine", conn: conn)
      assert turn.commit_before == nil
      done = eventually(turn_done(turn.id))
      assert done.status == :completed
      assert done.commit_after == nil
    end

    test "model: switches the model for this and later turns", %{dir: dir, conn: conn} do
      project = git_project!(dir)
      {:ok, thread} = Projects.start_thread(project, conn: conn)
      {:ok, turn} = Projects.send_message(thread, "say a", conn: conn, model: "glm-5")
      assert turn.model_slug == "glm-5"
      assert Ash.get!(Thread, thread.id).model_slug == "glm-5"
      eventually(turn_done(turn.id))

      {:ok, turn2} = Projects.send_message(thread, "say b", conn: conn)
      assert turn2.model_slug == "glm-5"
    end

    test "turns are listed oldest first", %{dir: dir, conn: conn} do
      project = git_project!(dir)
      {:ok, thread} = Projects.start_thread(project, conn: conn)
      {:ok, t1} = Projects.send_message(thread, "say 1", conn: conn)
      eventually(turn_done(t1.id))
      {:ok, t2} = Projects.send_message(thread, "say 2", conn: conn)
      eventually(turn_done(t2.id))
      assert Enum.map(Projects.list_turns!(thread), & &1.id) == [t1.id, t2.id]
    end
  end

  describe "restoring the files a turn started from" do
    setup %{dir: dir, conn: conn} do
      project = git_project!(dir)
      {:ok, thread} = Projects.start_thread(project, conn: conn)
      {:ok, turn} = Projects.send_message(thread, "say go", conn: conn)
      eventually(turn_done(turn.id))
      # "the agent" changed files during/after the turn
      File.write!(Path.join(dir, "a.txt"), "changed by agent\n")
      File.write!(Path.join(dir, "new.txt"), "new\n")
      %{project: project, thread: thread, turn: turn}
    end

    test "restore_proposal/1 describes what would happen", %{turn: turn} do
      assert {:ok, proposal} = Projects.restore_proposal(turn)
      assert proposal.commit == turn.commit_before
      assert proposal.dirty_now?
      assert proposal.changed_files == ["a.txt", "new.txt"]
      assert proposal.later_turns == 0
    end

    test "restore_files/2 requires explicit confirmation", %{turn: turn} do
      assert {:error, :confirmation_required} = Projects.restore_files(turn)
      assert {:error, :confirmation_required} = Projects.restore_files(turn, confirm: false)
    end

    test "restore_files/2 makes a safety commit, then puts the files back; history keeps everything",
         %{dir: dir, turn: turn} do
      assert {:ok, %{safety_commit: safety, head: head}} =
               Projects.restore_files(turn, confirm: true)

      assert is_binary(safety)
      assert File.read!(Path.join(dir, "a.txt")) == "v1\n"
      refute File.exists?(Path.join(dir, "new.txt"))
      # the safety commit is on the branch, the restore itself is a working-tree change
      assert head == safety
      assert [%{subject: subject} | _] = Git.log(dir, limit: 1)
      assert subject =~ "longx: before restoring"
    end

    test "restore_files/2 with mode: :reset_hard moves the branch back", %{dir: dir, turn: turn} do
      assert {:ok, %{head: head}} = Projects.restore_files(turn, confirm: true, mode: :reset_hard)
      assert head == turn.commit_before
      assert {:ok, ^head} = Git.head(dir)
      assert File.read!(Path.join(dir, "a.txt")) == "v1\n"
    end

    test "a turn without a bookmark cannot be restored", %{conn: conn} do
      # a directory outside any repository
      plain = Path.join(System.tmp_dir!(), "longx-plain-#{System.unique_integer([:positive])}")
      File.mkdir_p!(plain)
      on_exit(fn -> File.rm_rf!(plain) end)
      project = plain_project!(plain)
      {:ok, thread} = Projects.start_thread(project, conn: conn)
      {:ok, turn} = Projects.send_message(thread, "say x", conn: conn)
      assert {:error, :no_git} = Projects.restore_proposal(turn)
      assert {:error, :no_git} = Projects.restore_files(turn, confirm: true)
    end
  end
end
