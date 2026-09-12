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

  # a second model codex can be switched to; "deepseek-flash" (the default) comes from the seeds
  defp glm!(attrs \\ %{}) do
    case Longx.AI.get_model_by_slug("glm-5") do
      {:ok, model} ->
        model

      {:error, _} ->
        provider =
          Longx.AI.create_provider!(%{
            name: "GLM",
            slug: "glm-#{System.unique_integer([:positive])}",
            base_url: "https://open.bigmodel.cn/api/paas/v4",
            api_key: "sk-glm"
          })

        Longx.AI.create_model!(
          Map.merge(
            %{name: "GLM 5", upstream_id: "glm-5", slug: "glm-5", provider_id: provider.id},
            attrs
          )
        )
    end
  end

  defp read_thread!(conn, codex_thread_id) do
    {:ok, %{"thread" => thread}} =
      Connection.request(conn, "thread/read", %{"threadId" => codex_thread_id})

    thread
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

    test "the chosen model's settings reach codex, not the project default's", %{
      dir: dir,
      conn: conn
    } do
      glm!(%{context_window: 200_000, reasoning_effort: "high", reasoning_summary: :auto})

      # no search provider → this model gets no web search at all
      Ash.bulk_destroy!(Longx.AI.SearchProvider, :destroy, %{}, authorize?: false)
      project = git_project!(dir)
      {:ok, thread} = Projects.start_thread(project, conn: conn, model: "glm-5")

      %{"startParams" => params} = read_thread!(conn, thread.codex_thread_id)
      assert params["model"] == "glm-5"

      assert params["config"] == %{
               "model_context_window" => 200_000,
               "model_reasoning_effort" => "high",
               "model_reasoning_summary" => "auto",
               "web_search" => "disabled",
               "features.standalone_web_search" => false
             }
    end

    test "the default model's settings apply without naming it (codex keeps its placeholder)", %{
      dir: dir,
      conn: conn
    } do
      project = git_project!(dir)
      {:ok, thread} = Projects.start_thread(project, conn: conn)

      %{"startParams" => params} = read_thread!(conn, thread.codex_thread_id)
      refute Map.has_key?(params, "model")
      assert params["config"]["model_context_window"] == 128_000
    end

    test "an unknown model is refused before codex is involved", %{dir: dir, conn: conn} do
      project = git_project!(dir)

      assert {:error, {:unknown_model, "nope"}} =
               Projects.start_thread(project, conn: conn, model: "nope")

      assert Projects.list_threads!(project) == []
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

    test "model: switches the model for this and later turns, with its reasoning settings", %{
      dir: dir,
      conn: conn
    } do
      glm!(%{reasoning_effort: "low", reasoning_summary: :concise})
      project = git_project!(dir)
      {:ok, thread} = Projects.start_thread(project, conn: conn)
      {:ok, turn} = Projects.send_message(thread, "say a", conn: conn, model: "glm-5")
      assert turn.model_slug == "glm-5"
      assert Ash.get!(Thread, thread.id).model_slug == "glm-5"
      eventually(turn_done(turn.id))

      %{"lastTurnParams" => params} = read_thread!(conn, thread.codex_thread_id)
      assert params["model"] == "glm-5"
      assert params["effort"] == "low"
      assert params["summary"] == "concise"

      {:ok, turn2} = Projects.send_message(thread, "say b", conn: conn)
      assert turn2.model_slug == "glm-5"

      assert {:error, {:unknown_model, "nope"}} =
               Projects.send_message(thread, "say c", conn: conn, model: "nope")
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

  describe "redo_turn/2 — from turn N again, with another model" do
    setup %{dir: dir, conn: conn} do
      glm!()
      project = git_project!(dir)
      {:ok, thread} = Projects.start_thread(project, conn: conn)
      Longx.Codex.Thread.subscribe(thread.codex_thread_id)
      {:ok, t1} = Projects.send_message(thread, "say one", conn: conn)
      eventually(turn_done(t1.id))
      {:ok, t2} = Projects.send_message(thread, "say two", conn: conn)
      eventually(turn_done(t2.id))
      {:ok, t3} = Projects.send_message(thread, "say three", conn: conn)
      eventually(turn_done(t3.id))
      # the agent left a mess after turn 2
      File.write!(Path.join(dir, "a.txt"), "broken\n")
      %{project: project, thread: thread, t1: t1, t2: t2, t3: t3}
    end

    test "revert mode: drops turn N and later in codex and the projection, marks rows, re-runs with the new model",
         %{conn: conn, thread: thread, t1: t1, t2: t2, t3: t3} do
      assert {:ok, %Turn{} = redo} = Projects.redo_turn(t2, model: "glm-5", conn: conn)

      assert redo.user_text == "say two"
      assert redo.model_slug == "glm-5"
      assert Ash.get!(Turn, t2.id).status == :reverted
      assert Ash.get!(Turn, t3.id).status == :reverted
      assert Ash.get!(Turn, t1.id).status == :completed

      # the thread's projection only has turn 1 plus the redo
      assert_receive {:codex, _, "thread/reverted", %{"turnIds" => ids}}, 5_000
      assert Enum.sort(ids) == Enum.sort([t2.codex_turn_id, t3.codex_turn_id])
      done = eventually(turn_done(redo.id))
      assert done.status == :completed

      turn_ids =
        Longx.Codex.Thread.snapshot(thread.codex_thread_id).items
        |> Enum.map(& &1["turnId"])
        |> Enum.uniq()

      assert turn_ids == [t1.codex_turn_id, redo.codex_turn_id]

      # and codex's own history agrees
      {:ok, read} =
        Connection.request(conn, "thread/read", %{
          "threadId" => thread.codex_thread_id,
          "includeTurns" => true
        })

      assert Enum.map(read["thread"]["turns"], & &1["id"]) == [
               t1.codex_turn_id,
               redo.codex_turn_id
             ]

      # listing shows the live turns only, unless asked
      assert Enum.map(Projects.list_turns!(thread), & &1.id) == [t1.id, redo.id]
      assert length(Projects.list_turns!(thread, include_reverted: true)) == 4
      assert Ash.get!(Thread, thread.id).model_slug == "glm-5"
    end

    test "text: replaces the user message; restore_files: true puts the tree back first", %{
      conn: conn,
      dir: dir,
      t2: t2
    } do
      assert {:ok, redo} =
               Projects.redo_turn(t2, text: "say two-but-better", restore_files: true, conn: conn)

      assert redo.user_text == "say two-but-better"
      refute redo.dirty_start
      # the mess is gone (restored to before turn 2, then the preflight found a clean tree)
      assert File.read!(Path.join(dir, "a.txt")) == "v1\n"

      assert [%{subject: subject} | _] =
               Git.log(dir, limit: 2) |> Enum.reject(&(&1.subject =~ "before turn"))

      assert subject =~ "longx: before restoring"
    end

    test "fork mode: a new thread with the history before N; the original is untouched", %{
      conn: conn,
      thread: thread,
      t1: t1,
      t2: t2
    } do
      assert {:ok, redo} = Projects.redo_turn(t2, mode: :fork, model: "glm-5", conn: conn)
      forked = Ash.get!(Thread, redo.thread_id)
      refute forked.id == thread.id
      assert forked.forked_from_id == thread.id
      assert forked.model_slug == "glm-5"
      assert forked.project_id == thread.project_id

      eventually(turn_done(redo.id))

      {:ok, read} =
        Connection.request(conn, "thread/read", %{
          "threadId" => forked.codex_thread_id,
          "includeTurns" => true
        })

      assert Enum.map(read["thread"]["turns"], & &1["id"]) == [
               t1.codex_turn_id,
               redo.codex_turn_id
             ]

      # nothing happened to the original
      assert Ash.get!(Turn, t2.id).status == :completed
      assert length(Projects.list_turns!(thread)) == 3
    end

    test "refuses while a turn is in progress", %{conn: conn, thread: thread, t2: t2} do
      {:ok, running} = Projects.send_message(thread, "stall", conn: conn)
      assert {:error, {:turn_in_progress, id}} = Projects.redo_turn(t2, conn: conn)
      assert id == running.id
      :ok = Connection.notify(conn, "fake/continue", %{})
      eventually(turn_done(running.id))
    end

    test "a reverted turn cannot be redone again", %{conn: conn, t2: t2, t3: t3} do
      {:ok, redo} = Projects.redo_turn(t2, conn: conn)
      eventually(turn_done(redo.id))
      assert {:error, :turn_reverted} = Projects.redo_turn(t3, conn: conn)
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
