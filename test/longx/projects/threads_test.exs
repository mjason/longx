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

  defp eventually(fun, attempts \\ 300) do
    case fun.() do
      {:ok, value} ->
        value

      _ when attempts > 0 ->
        Process.sleep(30)
        eventually(fun, attempts - 1)

      other ->
        flunk("condition not met: #{inspect(other)}")
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
      # nothing chosen = the globally enabled set (the memory tools by default)
      assert thread.tools == ["memory.note", "memory.read", "memory.search"]
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

      assert Map.delete(params["config"], "sandbox_workspace_write.writable_roots") == %{
               "model_context_window" => 200_000,
               "model_reasoning_effort" => "high",
               "model_reasoning_summary" => "auto",
               "web_search" => "live",
               "features.standalone_web_search" => true,
               "features.multi_agent_v2" => true,
               "approvals_reviewer" => "auto_review"
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
      # the seeded default model's window (DeepSeek V4 Flash: 1M)
      assert params["config"]["model_context_window"] == Longx.AI.default_model!().context_window
      assert params["config"]["model_context_window"] == 1_000_000
    end

    test "network_access: true opens the workspace-write sandbox's network", %{
      dir: dir,
      conn: conn
    } do
      closed = git_project!(dir)
      {:ok, thread} = Projects.start_thread(closed, conn: conn)
      %{"startParams" => params} = read_thread!(conn, thread.codex_thread_id)
      refute Map.has_key?(params["config"], "sandbox_workspace_write.network_access")

      sub = Path.join(dir, "open")
      File.mkdir_p!(sub)
      open = Projects.create_project!(%{name: "Open", root_path: sub, network_access: true})
      {:ok, thread} = Projects.start_thread(open, conn: conn)
      %{"startParams" => params} = read_thread!(conn, thread.codex_thread_id)
      assert params["config"]["sandbox_workspace_write.network_access"] == true
    end

    test "writable_roots: this user's cache directory always (like /tmp), plus the project's own — ~ expanded, missing ones skipped",
         %{dir: dir, conn: conn} do
      cache = Path.join(dir, "cache")
      File.mkdir_p!(cache)
      user_cache = Longx.Codex.Sandbox.cache_dir()

      # the project stores nothing by default; the sandbox still gets the user's
      # tool cache (uv, pip, npm… would fail read-only otherwise), when it exists
      assert git_project!(dir).writable_roots == []

      assert Projects.writable_roots(
               git_project!(Path.join(dir, "plain") |> tap(&File.mkdir_p!/1))
             ) == Enum.filter([user_cache], &File.dir?/1)

      sub = Path.join(dir, "sub")
      File.mkdir_p!(sub)
      project = git_project!(sub, %{writable_roots: ["~", cache, Path.join(dir, "nope")]})

      assert Projects.writable_roots(project) ==
               Enum.uniq(Enum.filter([user_cache], &File.dir?/1) ++ [Path.expand("~"), cache])

      {:ok, thread} = Projects.start_thread(project, conn: conn)
      %{"startParams" => params} = read_thread!(conn, thread.codex_thread_id)

      assert params["config"]["sandbox_workspace_write.writable_roots"] ==
               Projects.writable_roots(project)

      # every turn carries the policy with the project's current roots: an edit in the
      # settings reaches the open thread on its next turn, no resume needed
      {:ok, _} = Projects.send_message(thread, "hi", conn: conn)
      %{"lastTurnParams" => turn} = read_thread!(conn, thread.codex_thread_id)
      assert turn["sandboxPolicy"]["writableRoots"] == Projects.writable_roots(project)

      {:ok, project} = Projects.update_project(project, %{writable_roots: [cache]})
      thread = Ash.get!(Thread, thread.id)
      {:ok, _} = Projects.send_message(thread, "again", conn: conn)
      %{"lastTurnParams" => turn} = read_thread!(conn, thread.codex_thread_id)

      assert turn["sandboxPolicy"] == %{
               "type" => "workspaceWrite",
               "networkAccess" => false,
               "writableRoots" => Projects.writable_roots(project)
             }

      assert Projects.writable_roots(project) ==
               Enum.filter([user_cache], &File.dir?/1) ++ [cache]
    end

    test "passthrough_paths: this machine's GPU nodes always, plus the project's own patterns — globs expanded, only what exists",
         %{dir: dir} do
      # the GPU is part of every sandbox on a machine that has one (nvidia nodes,
      # WSL2's dxg, /dev/dri): a project moved to another box gets that box's devices
      gpu = Enum.find(Longx.Codex.Sandbox.presets(), %{paths: []}, &(&1.id == "gpu")).paths
      plain = git_project!(dir)
      assert plain.passthrough_paths == []
      assert Projects.passthrough_paths(plain) == gpu

      for n <- ~w(x1 x2), do: File.touch!(Path.join(dir, n))
      sub = Path.join(dir, "sub")
      File.mkdir_p!(sub)

      project =
        git_project!(sub, %{
          passthrough_paths: ["/dev/null", Path.join(dir, "x*"), "/nope/at/all", "/dev/null"]
        })

      assert Projects.passthrough_paths(project) ==
               Enum.sort(gpu ++ ["/dev/null", Path.join(dir, "x1"), Path.join(dir, "x2")])
    end

    test "an unknown model is refused before codex is involved", %{dir: dir, conn: conn} do
      project = git_project!(dir)

      assert {:error, {:unknown_model, "nope"}} =
               Projects.start_thread(project, conn: conn, model: "nope")

      assert Projects.list_threads!(project) == []
    end
  end

  describe "search_files/3" do
    test "asks the project's codex for fuzzy file matches under the root", %{dir: dir, conn: conn} do
      project = git_project!(dir)
      File.mkdir_p!(Path.join(dir, "lib/longx"))
      File.write!(Path.join(dir, "lib/longx/gateway.ex"), "")
      File.write!(Path.join(dir, "lib/longx/git.ex"), "")

      assert {:ok, matches} = Projects.search_files(project, "gtw", conn: conn)

      assert [%{path: "lib/longx/gateway.ex", file_name: "gateway.ex", match_type: "file"} | _] =
               matches

      refute Enum.any?(matches, &(&1.path == "lib/longx/git.ex"))
      # codex's index sees .git too; nobody mentions those
      refute Enum.any?(matches, &String.starts_with?(&1.path, ".git/"))

      assert {:ok, []} = Projects.search_files(project, "", conn: conn)
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

    test "images go to codex with the text; the turn keeps the text only", %{dir: dir, conn: conn} do
      project = git_project!(dir)
      {:ok, thread} = Projects.start_thread(project, conn: conn)
      url = "data:image/png;base64,iVBORw0KGgo="

      {:ok, turn} = Projects.send_message(thread, "say what is this", conn: conn, images: [url])
      assert turn.user_text == "say what is this"
      eventually(turn_done(turn.id))

      %{"lastTurnParams" => params} = read_thread!(conn, thread.codex_thread_id)

      assert params["input"] == [
               %{"type" => "text", "text" => "say what is this"},
               %{"type" => "image", "url" => url}
             ]
    end

    test "compact_thread/2 asks codex to compact the context; not while a turn runs", %{
      dir: dir,
      conn: conn
    } do
      project = git_project!(dir)
      {:ok, thread} = Projects.start_thread(project, conn: conn)
      {:ok, turn} = Projects.send_message(thread, "say hi", conn: conn)
      eventually(turn_done(turn.id))

      assert :ok = Projects.compact_thread(thread, conn: conn)
      assert %{"compacted" => 1} = read_thread!(conn, thread.codex_thread_id)

      {:ok, _} = Projects.send_message(thread, "stall", conn: conn)
      assert {:error, :turn_in_progress} = Projects.compact_thread(thread, conn: conn)
    end

    test "review_thread/3 starts codex's review as a turn of the thread, with git bookmarks but no commit first",
         %{dir: dir, conn: conn} do
      project = git_project!(dir)
      {:ok, head} = Git.head(dir)
      {:ok, thread} = Projects.start_thread(project, conn: conn)
      File.write!(Path.join(dir, "a.txt"), "changed\n")

      assert {:ok, %Turn{} = turn} = Projects.review_thread(thread, :uncommitted, conn: conn)
      assert turn.user_text == "/review"
      assert turn.commit_before == head
      assert turn.dirty_start
      # the changes are what is being reviewed: nothing was committed
      assert {:ok, ^head} = Git.head(dir)

      done = eventually(turn_done(turn.id))
      assert done.status == :completed

      %{"lastReview" => review} = read_thread!(conn, thread.codex_thread_id)
      assert review["target"] == %{"type" => "uncommittedChanges"}
      assert review["delivery"] == "inline"
    end

    test "codex naming the thread fills an empty title; a title the person chose stays", %{
      dir: dir,
      conn: conn
    } do
      project = git_project!(dir)
      {:ok, thread} = Projects.start_thread(project, conn: conn)
      {:ok, turn} = Projects.send_message(thread, "name Fix the tests", conn: conn)
      eventually(turn_done(turn.id))
      assert Ash.get!(Thread, thread.id).title == "Fix the tests"

      {:ok, named} = Projects.rename_thread(Ash.get!(Thread, thread.id), %{title: "Mine"})
      {:ok, turn2} = Projects.send_message(named, "name Something else", conn: conn)
      eventually(turn_done(turn2.id))
      assert Ash.get!(Thread, thread.id).title == "Mine"
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

    test "effort: picks the reasoning level for this and later turns, recorded on the thread and the turn",
         %{dir: dir, conn: conn} do
      glm!(%{reasoning_levels: ["low", "high", "max"], reasoning_effort: "high"})
      project = git_project!(dir)

      # a thread starts on the model's default level…
      {:ok, thread} = Projects.start_thread(project, conn: conn, model: "glm-5")
      assert Ash.get!(Thread, thread.id).reasoning_effort == "high"
      %{"startParams" => params} = read_thread!(conn, thread.codex_thread_id)
      assert params["config"]["model_reasoning_effort"] == "high"

      # …or on the one chosen
      {:ok, low} = Projects.start_thread(project, conn: conn, model: "glm-5", effort: "low")
      assert Ash.get!(Thread, low.id).reasoning_effort == "low"
      %{"startParams" => params} = read_thread!(conn, low.codex_thread_id)
      assert params["config"]["model_reasoning_effort"] == "low"

      # a turn that changes the level sends it (codex keeps it for the turns after)
      {:ok, turn} = Projects.send_message(thread, "say a", conn: conn, effort: "max")
      assert turn.reasoning_effort == "max"
      assert Ash.get!(Thread, thread.id).reasoning_effort == "max"
      eventually(turn_done(turn.id))
      %{"lastTurnParams" => params} = read_thread!(conn, thread.codex_thread_id)
      assert params["effort"] == "max"
      # the model did not change, so it is not named again
      refute Map.has_key?(params, "model")

      # the same level again, or none given: nothing sent, the turn records what is in force
      {:ok, turn2} = Projects.send_message(thread, "say b", conn: conn)
      assert turn2.reasoning_effort == "max"
      eventually(turn_done(turn2.id))
      %{"lastTurnParams" => params} = read_thread!(conn, thread.codex_thread_id)
      refute Map.has_key?(params, "effort")

      # a level the model does not offer is refused before codex is involved
      assert {:error, {:unknown_effort, "ultra"}} =
               Projects.send_message(thread, "say c", conn: conn, effort: "ultra")

      assert {:error, {:unknown_effort, "ultra"}} =
               Projects.start_thread(project, conn: conn, model: "glm-5", effort: "ultra")

      # switching models takes the new model's default level unless one is chosen
      flash =
        Longx.AI.update_model!(Longx.AI.default_model!(), %{
          reasoning_levels: ["low", "high"],
          reasoning_effort: "high"
        })

      {:ok, turn3} = Projects.send_message(thread, "say d", conn: conn, model: flash.slug)
      assert turn3.reasoning_effort == "high"
      eventually(turn_done(turn3.id))
      %{"lastTurnParams" => params} = read_thread!(conn, thread.codex_thread_id)
      assert params["model"] == flash.slug
      assert params["effort"] == "high"

      {:ok, turn4} =
        Projects.send_message(thread, "say e", conn: conn, model: "glm-5", effort: "low")

      assert turn4.reasoning_effort == "low"
      eventually(turn_done(turn4.id))
      %{"lastTurnParams" => params} = read_thread!(conn, thread.codex_thread_id)
      assert params == Map.merge(params, %{"model" => "glm-5", "effort" => "low"})

      # a model without declared levels takes any effort (whatever it advertises)
      Longx.AI.update_model!(flash, %{reasoning_levels: [], reasoning_effort: nil})

      {:ok, turn5} =
        Projects.send_message(thread, "say f", conn: conn, model: flash.slug, effort: "ultra")

      assert turn5.reasoning_effort == "ultra"
    end

    test "a thread resumes with its own access mode and the memory, not codex's defaults (a full-access thread fell back to workspace-write after every restart)",
         %{dir: dir, conn: conn} do
      project = git_project!(dir)

      {:ok, thread} =
        Projects.start_thread(project,
          conn: conn,
          sandbox: :danger_full_access,
          approval_policy: :never
        )

      assert {:ok, _} = Projects.resume_thread(Ash.get!(Thread, thread.id, load: :project), conn)
      %{"resumeParams" => params} = read_thread!(conn, thread.codex_thread_id)
      assert params["sandbox"] == "danger-full-access"
      assert params["approvalPolicy"] == "never"
      assert params["cwd"] == project.root_path
      assert params["developerInstructions"] =~ "Longx 全局记忆"
    end

    test "a thread resumes with the level it was left on, not the model's default", %{
      dir: dir,
      conn: conn
    } do
      glm!(%{reasoning_levels: ["low", "high"], reasoning_effort: "high"})
      project = git_project!(dir)
      {:ok, thread} = Projects.start_thread(project, conn: conn, model: "glm-5", effort: "low")

      assert {:ok, _} = Projects.resume_thread(Ash.get!(Thread, thread.id, load: :project), conn)
      %{"resumeParams" => params} = read_thread!(conn, thread.codex_thread_id)
      assert params["config"]["model_reasoning_effort"] == "low"
    end

    test "sandbox / approval_policy / network_access switch the access mode from this turn on and are recorded on the thread",
         %{dir: dir, conn: conn} do
      project = git_project!(dir)
      {:ok, thread} = Projects.start_thread(project, conn: conn)
      # the thread starts with the project's defaults
      assert %{sandbox: :workspace_write, approval_policy: :on_request, network_access: false} =
               Ash.get!(Thread, thread.id)

      {:ok, turn} =
        Projects.send_message(thread, "say a",
          conn: conn,
          sandbox: :danger_full_access,
          approval_policy: :never,
          network_access: true
        )

      eventually(turn_done(turn.id))
      %{"lastTurnParams" => params} = read_thread!(conn, thread.codex_thread_id)
      assert params["sandboxPolicy"] == %{"type" => "dangerFullAccess"}
      assert params["approvalPolicy"] == "never"

      assert %{sandbox: :danger_full_access, approval_policy: :never, network_access: true} =
               Ash.get!(Thread, thread.id)

      # nothing given: the thread keeps its mode, nothing is sent
      {:ok, turn2} = Projects.send_message(thread, "say b", conn: conn)
      eventually(turn_done(turn2.id))
      # every turn carries the policy in force (codex keeps it, but the writable roots
      # are the project's *current* ones — an edit applies from the next turn on)
      %{"lastTurnParams" => params2} = read_thread!(conn, thread.codex_thread_id)
      assert params2["sandboxPolicy"] == %{"type" => "dangerFullAccess"}
      assert Ash.get!(Thread, thread.id).sandbox == :danger_full_access
    end

    test "the global memory reaches a new thread as developer instructions and the memory tools, unless the project opts out",
         %{dir: dir, conn: conn} do
      project = git_project!(dir)
      {:ok, thread} = Projects.start_thread(project, conn: conn)
      %{"startParams" => params} = read_thread!(conn, thread.codex_thread_id)
      assert [%{"name" => "memory"}] = params["dynamicTools"]
      assert params["developerInstructions"] =~ "Longx 全局记忆"
      assert params["developerInstructions"] =~ "调用 `note`"

      {:ok, quiet} = Projects.update_project(project, %{global_memory: false})
      {:ok, thread} = Projects.start_thread(quiet, conn: conn)
      %{"startParams" => params} = read_thread!(conn, thread.codex_thread_id)
      refute Map.has_key?(params, "developerInstructions")
    end

    test "web_search: false at start turns codex's web.run off for the thread; the project's default applies otherwise",
         %{dir: dir, conn: conn} do
      project = git_project!(dir)
      assert project.web_search == true

      {:ok, on} = Projects.start_thread(project, conn: conn)
      assert on.web_search == true
      %{"startParams" => params} = read_thread!(conn, on.codex_thread_id)
      refute params["config"]["web_search"] == "disabled"

      {:ok, off} = Projects.start_thread(project, conn: conn, web_search: false)
      assert off.web_search == false
      %{"startParams" => params} = read_thread!(conn, off.codex_thread_id)
      assert params["config"]["web_search"] == "disabled"
      assert params["config"]["features.standalone_web_search"] == false

      quiet = Projects.update_project!(project, %{web_search: false})
      {:ok, inherited} = Projects.start_thread(quiet, conn: conn)
      assert inherited.web_search == false
    end

    test "multi_agent: false at start keeps codex's sub-agent tools off; the project's default applies otherwise",
         %{dir: dir, conn: conn} do
      project = git_project!(dir)
      assert project.multi_agent == true

      {:ok, on} = Projects.start_thread(project, conn: conn)
      assert on.multi_agent == true
      %{"startParams" => params} = read_thread!(conn, on.codex_thread_id)
      assert params["config"]["features.multi_agent_v2"] == true

      {:ok, off} = Projects.start_thread(project, conn: conn, multi_agent: false)
      assert off.multi_agent == false
      %{"startParams" => params} = read_thread!(conn, off.codex_thread_id)
      assert params["config"]["features.multi_agent"] == false
    end

    test "auto_review: on by default — codex's Guardian reviews approvals instead of the person; off at start or as the project's default",
         %{dir: dir, conn: conn} do
      project = git_project!(dir)
      assert project.auto_review == true

      {:ok, on} = Projects.start_thread(project, conn: conn)
      assert on.auto_review == true
      %{"startParams" => params} = read_thread!(conn, on.codex_thread_id)
      assert params["config"]["approvals_reviewer"] == "auto_review"

      {:ok, off} = Projects.start_thread(project, conn: conn, auto_review: false)
      assert off.auto_review == false
      %{"startParams" => params} = read_thread!(conn, off.codex_thread_id)
      assert params["config"]["approvals_reviewer"] == "user"

      manual = Projects.update_project!(project, %{auto_review: false})
      {:ok, inherited} = Projects.start_thread(manual, conn: conn)
      assert inherited.auto_review == false
    end

    test "approve_denied_review/2 hands a denied review back to codex as approved by the person",
         %{dir: dir, conn: conn} do
      project = git_project!(dir)
      {:ok, thread} = Projects.start_thread(project, conn: conn)
      id = thread.codex_thread_id
      :ok = Longx.Codex.Thread.subscribe(id)

      Longx.Codex.ThreadState.ingest(id, "item/autoApprovalReview/completed", %{
        "threadId" => id,
        "turnId" => "t1",
        "reviewId" => "rev-1",
        "action" => %{
          "type" => "command",
          "source" => "unifiedExec",
          "command" => "ls",
          "cwd" => dir
        },
        "review" => %{"status" => "denied", "riskLevel" => "high", "rationale" => "no"}
      })

      assert_receive {:codex, _, "item/autoApprovalReview/completed", _}, 5_000
      assert :ok = Projects.approve_denied_review(thread, "rev-1", conn: conn)
      assert_receive {:codex, _, "item/autoApprovalReview/userApproved", _}, 5_000
      assert %{"approvedGuardianEvents" => [%{"id" => "rev-1"}]} = read_thread!(conn, id)
      assert {:error, :not_found} = Projects.approve_denied_review(thread, "rev-9", conn: conn)
    end

    test "approval_policy :auto_accept (全部放行): the turn switches the reviewer off and Longx answers every approval; back to on-request restores the reviewer",
         %{dir: dir, conn: conn} do
      project = git_project!(dir)
      {:ok, thread} = Projects.start_thread(project, conn: conn)
      id = thread.codex_thread_id
      :ok = Longx.Codex.Thread.subscribe(id)

      {:ok, turn} =
        Projects.send_message(thread, "approve make", conn: conn, approval_policy: :auto_accept)

      eventually(turn_done(turn.id))
      refute_received {:codex, _, "item/commandExecution/requestApproval", _}
      assert Ash.get!(Thread, thread.id).approval_policy == :auto_accept
      assert Longx.Codex.ThreadState.Store.auto_accept?(id)
      read = read_thread!(conn, id)
      assert read["lastTurnParams"]["approvalPolicy"] == "on-request"
      assert read["settings"]["approvalsReviewer"] == "user"

      {:ok, turn2} =
        Projects.send_message(thread, "say b", conn: conn, approval_policy: :on_request)

      eventually(turn_done(turn2.id))
      refute Longx.Codex.ThreadState.Store.auto_accept?(id)
      assert read_thread!(conn, id)["settings"]["approvalsReviewer"] == "auto_review"

      # a project default of 全部放行 starts threads that way (the reviewer never on)
      open = Projects.update_project!(project, %{approval_policy: :auto_accept})
      {:ok, t2} = Projects.start_thread(open, conn: conn)
      assert t2.approval_policy == :auto_accept
      assert Longx.Codex.ThreadState.Store.auto_accept?(t2.codex_thread_id)

      assert read_thread!(conn, t2.codex_thread_id)["startParams"]["config"]["approvals_reviewer"] ==
               "user"
    end

    test "a goal (codex's goal mode): set / clear through the thread; a turn codex starts on its own gets a Turn row like any other, bookmarked",
         %{dir: dir, conn: conn} do
      project = git_project!(dir)
      {:ok, thread} = Projects.start_thread(project, conn: conn)
      :ok = Longx.Codex.Thread.subscribe(thread.codex_thread_id)

      assert {:ok, %{"objective" => "auto: keep going", "status" => "active"}} =
               Projects.set_goal(thread, %{objective: "auto: keep going", token_budget: 5000},
                 conn: conn
               )

      # the fake continues the goal with a turn nobody asked for
      assert_receive {:codex, _, "turn/completed", %{"turn" => %{"id" => codex_turn_id}}}, 10_000
      turn = eventually(fn -> Projects.get_turn_by_codex_id(codex_turn_id) end)
      assert turn.status == :completed
      assert turn.user_text == "（目标续跑）auto: keep going"
      assert {:ok, turn.commit_before} == Git.head(dir)
      assert Ash.get!(Thread, thread.id).status == :idle
      assert [_] = Projects.list_turns!(thread)

      assert {:ok, %{"status" => "paused"}} =
               Projects.set_goal(thread, %{status: :paused}, conn: conn)

      assert {:ok, true} = Projects.clear_goal(thread, conn: conn)
      # the view follows the notification, not the reply
      assert_receive {:codex, _, "thread/goal/cleared", _}, 5_000
      assert Longx.Codex.Thread.snapshot(thread.codex_thread_id).goal == nil
    end

    test "send_message/3 with skills: the named SKILL.md files ride on the turn as skill inputs; list_skills/2 asks codex",
         %{dir: dir, conn: conn} do
      project = git_project!(dir)

      assert {:ok, [%{name: "review-agent"}, %{name: "docs", path: docs}]} =
               Projects.list_skills(project, conn: conn)

      {:ok, thread} = Projects.start_thread(project, conn: conn)

      {:ok, turn} =
        Projects.send_message(thread, "say use $docs",
          conn: conn,
          skills: [%{name: "docs", path: docs}]
        )

      eventually(turn_done(turn.id))
      %{"lastTurnParams" => params} = read_thread!(conn, thread.codex_thread_id)

      assert [%{"type" => "text"}, %{"type" => "skill", "name" => "docs", "path" => ^docs}] =
               params["input"]
    end

    test "retract_turn/2: a running turn that did no I/O is interrupted and taken out of the history, its text handed back; one that ran something (or waits to) is only interrupted",
         %{dir: dir, conn: conn} do
      project = git_project!(dir)
      {:ok, thread} = Projects.start_thread(project, conn: conn)
      :ok = Longx.Codex.Thread.subscribe(thread.codex_thread_id)

      {:ok, turn} = Projects.send_message(thread, "wait", conn: conn)
      assert_receive {:codex, _, "item/completed", %{"item" => %{"type" => "userMessage"}}}, 5_000

      assert {:ok, %{text: "wait"}} = Projects.retract_turn(thread, turn, conn: conn)
      assert %{status: :reverted} = Ash.get!(Turn, turn.id)
      assert Projects.list_turns!(thread) == []
      # the view no longer shows the message either
      refute Enum.any?(
               Longx.Codex.Thread.snapshot(thread.codex_thread_id).items,
               &(&1["turnId"] == turn.codex_turn_id)
             )

      assert Ash.get!(Thread, thread.id).status == :idle

      # text the model started to say is no side effect: still safe to take back
      {:ok, stalled} = Projects.send_message(thread, "stall", conn: conn)
      assert_receive {:codex, _, "item/agentMessage/delta", _}, 5_000
      assert {:ok, %{text: "stall"}} = Projects.retract_turn(thread, stalled, conn: conn)
      assert %{status: :reverted} = Ash.get!(Turn, stalled.id)
      assert Projects.list_turns!(thread) == []

      # a turn waiting to run a command (an approval pending) is not retracted
      {:ok, asking} = Projects.send_message(thread, "approve ls", conn: conn)

      assert_receive {:codex, _, "item/commandExecution/requestApproval", %{"requestId" => rid}},
                     5_000

      assert {:error, :has_output} = Projects.retract_turn(thread, asking, conn: conn)
      assert Ash.get!(Turn, asking.id).status == :in_progress
      :ok = Longx.Codex.Thread.respond(rid, :decline, conn: conn)
      eventually(turn_done(asking.id))

      # a turn that is over is not retracted either
      assert {:error, :not_running} = Projects.retract_turn(thread, asking, conn: conn)
    end

    test "the notify feed hears about a turn waiting on the person and a turn done",
         %{dir: dir, conn: conn} do
      project = git_project!(dir)
      :ok = Phoenix.PubSub.subscribe(Longx.PubSub, Longx.Notify.topic())
      {:ok, thread} = Projects.start_thread(project, conn: conn)
      :ok = Longx.Codex.Thread.subscribe(thread.codex_thread_id)
      url = "/p/#{project.slug}/t/#{thread.id}"

      # an approval request = the turn waits on the person
      {:ok, asking} = Projects.send_message(thread, "approve ls", conn: conn)

      assert_receive {:codex, _, "item/commandExecution/requestApproval", %{"requestId" => rid}},
                     5_000

      assert_receive {:notify, %{kind: "approval", url: ^url, body: body, thread_id: tid}}, 5_000
      assert body =~ "ls"
      assert tid == thread.id
      :ok = Longx.Codex.Thread.respond(rid, :decline, conn: conn)
      eventually(turn_done(asking.id))
      assert_receive {:notify, %{kind: "turn_completed", url: ^url}}, 5_000
    end

    test "a turn reverted while it was still ending stays reverted when its turn/completed lands",
         %{dir: dir, conn: conn} do
      project = git_project!(dir)
      {:ok, thread} = Projects.start_thread(project, conn: conn)
      :ok = Longx.Codex.Thread.subscribe(thread.codex_thread_id)
      {:ok, turn} = Projects.send_message(thread, "wait", conn: conn)
      assert_receive {:codex, _, "item/completed", %{"item" => %{"type" => "userMessage"}}}, 5_000

      # the retract marks the row before the interrupt; the Tracker's completion
      # (a git call later) must not turn it back into an interrupted turn
      Projects.mark_turn_reverted!(turn)
      :ok = Longx.Codex.Thread.interrupt(thread.codex_thread_id, turn.codex_turn_id, conn: conn)
      assert_receive {:codex, _, "turn/completed", _}, 5_000

      eventually(fn ->
        case Ash.get!(Thread, thread.id) do
          %{status: :idle} = t -> {:ok, t}
          _ -> :pending
        end
      end)

      assert Ash.get!(Turn, turn.id).status == :reverted
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
