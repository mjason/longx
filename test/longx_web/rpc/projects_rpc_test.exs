defmodule LongxWeb.ProjectsRpcTest do
  @moduledoc """
  The typed RPC surface the SPA uses (`POST /rpc/run`, ash_typescript):
  projects, their git, threads and turns. Exercised at the wire so the
  generated client's contract is what is tested. Bypass plays the model.
  """
  use LongxWeb.ConnCase, async: false

  alias Longx.Agent.ThreadState
  alias Longx.AI
  alias Longx.Projects
  alias Longx.Test.ResponsesFixture

  setup do
    Ash.bulk_destroy!(Projects.Turn, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(Projects.Thread, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(Projects.Project, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(AI.Model, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(AI.Provider, :destroy, %{}, authorize?: false)

    bypass = Bypass.open()
    n = System.unique_integer([:positive])

    provider =
      AI.create_provider!(%{
        name: "Upstream #{n}",
        slug: "upstream-#{n}",
        base_url: "http://localhost:#{bypass.port}/v1",
        api_key: "sk-upstream"
      })

    model =
      AI.create_model!(%{
        name: "Fake",
        upstream_id: "real-model",
        slug: "fake-#{n}",
        provider_id: provider.id,
        reasoning_levels: ["low", "high"],
        reasoning_effort: "high"
      })

    AI.make_default_model!(model)

    dir = Path.join(System.tmp_dir!(), "longx-rpc-#{n}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      Longx.Test.Agents.stop_all!()
      File.rm_rf!(dir)
    end)

    %{dir: dir, bypass: bypass, model: model}
  end

  defp create!(conn, dir, extra \\ %{}) do
    %{"success" => true, "data" => project} =
      rpc(conn, "create_project", %{
        "fields" => ["id", "slug", "name", "rootPath", "webSearch"],
        "input" => Map.merge(%{"name" => "Demo App", "rootPath" => dir}, extra)
      })

    project
  end

  defp start!(conn, project) do
    %{"success" => true, "data" => %{"id" => thread_id, "kernelThreadId" => kernel_id}} =
      rpc(conn, "start_thread", %{
        "fields" => ["id", "kernelThreadId", "status"],
        "input" => %{"projectId" => project["id"]}
      })

    {thread_id, kernel_id}
  end

  test "project_jobs lists background jobs with their conversation, limited to the project", %{
    conn: conn,
    dir: dir
  } do
    project = create!(conn, dir)
    {thread_id, kernel_id} = start!(conn, project)
    {:ok, _} = Longx.Jobs.start(kernel_id, "compile", "sleep 30", cwd: dir, notify: false)
    on_exit(fn -> Longx.Jobs.delete(kernel_id) end)

    other_dir = Path.join(dir, "other")
    File.mkdir_p!(other_dir)
    other_project = create!(conn, other_dir, %{"name" => "Other project"})
    {_other_thread, other_kernel_id} = start!(conn, other_project)

    {:ok, _} =
      Longx.Jobs.start(other_kernel_id, "elsewhere", "sleep 30", cwd: other_dir, notify: false)

    on_exit(fn -> Longx.Jobs.delete(other_kernel_id) end)

    assert %{"success" => true, "data" => %{"jobs" => [job]}} =
             rpc(conn, "project_jobs", %{
               "fields" => ["jobs"],
               "input" => %{"projectId" => project["id"]}
             })

    assert job["name"] == "compile"
    assert job["status"] == "running"
    assert job["thread_id"] == thread_id
    assert job["thread_title"] == nil
  end

  defp sse(conn, chunks) do
    conn =
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    Enum.reduce(chunks, conn, fn chunk, c ->
      {:ok, c} = Plug.Conn.chunk(c, chunk)
      c
    end)
  end

  # the model's replies in order; a function holds the reply until told :go; a
  # request past the script (a /compact summary the test does not care about)
  # gets a 503 instead of crashing the handler
  defp script!(bypass, replies) do
    {:ok, queue} = Elixir.Agent.start_link(fn -> replies end)

    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      case Elixir.Agent.get_and_update(queue, fn
             [h | t] -> {h, t}
             [] -> {:exhausted, []}
           end) do
        :exhausted -> Plug.Conn.send_resp(conn, 503, "script exhausted")
        reply when is_function(reply, 1) -> reply.(conn)
        chunks when is_list(chunks) -> sse(conn, chunks)
      end
    end)
  end

  defp held(chunks) do
    test = self()

    fn conn ->
      send(test, {:held, self()})

      receive do
        :go -> sse(conn, chunks)
      end
    end
  end

  defp assert_eventually(fun, attempts \\ 200) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition never held")

      true ->
        Process.sleep(25)
        assert_eventually(fun, attempts - 1)
    end
  end

  # the thread idle and no turn row left in progress (the Tracker idles the thread
  # first, then finishes the turn row — a list right after the idle saw in_progress)
  defp thread_idle(conn, project_id, thread_id) do
    assert_eventually(fn ->
      %{"success" => true, "data" => threads} =
        rpc(conn, "list_threads", %{
          "fields" => ["id", "status"],
          "input" => %{"projectId" => project_id}
        })

      %{"success" => true, "data" => turns} =
        rpc(conn, "list_turns", %{"fields" => ["status"], "input" => %{"threadId" => thread_id}})

      match?(%{"status" => "idle"}, Enum.find(threads, &(&1["id"] == thread_id))) and
        not Enum.any?(turns, &(&1["status"] == "in_progress"))
    end)
  end

  describe "projects" do
    test "create → list → get by slug → update → archive", %{conn: conn, dir: dir} do
      project = create!(conn, dir)
      assert project["slug"] == "demo-app"
      assert project["rootPath"] == Path.expand(dir)
      assert project["webSearch"] == true

      assert %{"success" => true, "data" => [%{"id" => id}]} =
               rpc(conn, "list_projects", %{"fields" => ["id"]})

      assert id == project["id"]

      assert %{"success" => true, "data" => %{"name" => "Demo App"}} =
               rpc(conn, "get_project", %{
                 "fields" => ["name"],
                 "input" => %{"slug" => "demo-app"}
               })

      assert %{"success" => true, "data" => %{"webSearch" => false, "trustLocalAgent" => true}} =
               rpc(conn, "update_project", %{
                 "fields" => ["webSearch", "trustLocalAgent"],
                 "identity" => id,
                 "input" => %{"webSearch" => false, "trustLocalAgent" => true}
               })

      assert %{"success" => true, "data" => %{"archivedAt" => at}} =
               rpc(conn, "archive_project", %{"fields" => ["archivedAt"], "identity" => id})

      assert is_binary(at)

      assert %{"success" => true, "data" => []} =
               rpc(conn, "list_projects", %{"fields" => ["id"]})
    end

    test "validation errors come back structured", %{conn: conn, dir: dir} do
      assert %{"success" => false, "errors" => [error | _]} =
               rpc(conn, "create_project", %{
                 "fields" => ["id"],
                 "input" => %{"name" => "x", "rootPath" => Path.join(dir, "missing")}
               })

      assert error["message"] =~ "existing directory"
      assert "rootPath" in error["fields"]
    end

    test "delete needs confirm and removes the project", %{conn: conn, dir: dir} do
      project = create!(conn, dir)

      assert %{"success" => false, "errors" => [%{"message" => message}]} =
               rpc(conn, "delete_project", %{"identity" => project["id"], "input" => %{}})

      assert message =~ "confirm"

      assert %{"success" => true} =
               rpc(conn, "delete_project", %{
                 "identity" => project["id"],
                 "input" => %{"confirm" => true}
               })

      assert %{"success" => true, "data" => []} =
               rpc(conn, "list_projects", %{"fields" => ["id"]})
    end
  end

  describe "git" do
    test "git_info and init_git", %{conn: conn, dir: dir} do
      project = create!(conn, dir)

      assert %{"success" => true, "data" => %{"repository" => false, "head" => nil}} =
               rpc(conn, "git_info", %{
                 "fields" => ["repository", "head", "clean", "changes", "lfs"],
                 "input" => %{"id" => project["id"]}
               })

      assert %{
               "success" => true,
               "data" => %{"repository" => true, "head" => sha, "clean" => true}
             } =
               rpc(conn, "init_git", %{
                 "fields" => ["repository", "head", "clean"],
                 "input" => %{"id" => project["id"]}
               })

      assert is_binary(sha)
    end
  end

  describe "threads and turns" do
    test "start_thread → send_message → list_threads / list_turns; stop, images, effort, /compact",
         %{conn: conn, dir: dir, bypass: bypass} do
      script!(bypass, [
        held(ResponsesFixture.assistant_message("hi")),
        ResponsesFixture.assistant_message("looked"),
        ResponsesFixture.assistant_message("low")
      ])

      project = create!(conn, dir)
      {thread_id, kernel_id} = start!(conn, project)
      assert kernel_id =~ ~r/^native_/

      assert %{"success" => true, "data" => %{"id" => turn_id, "status" => "in_progress"}} =
               rpc(conn, "send_message", %{
                 "fields" => ["id", "status", "userText"],
                 "input" => %{"threadId" => thread_id, "text" => "say hi"}
               })

      assert_receive {:held, _}, 5_000
      Bypass.pass(bypass)

      # the turn in flight can be stopped from the composer; a stale id is an error, not a crash
      %{"success" => true, "data" => [%{"kernelTurnId" => kernel_turn_id}]} =
        rpc(conn, "list_turns", %{
          "fields" => ["kernelTurnId"],
          "input" => %{"threadId" => thread_id}
        })

      assert %{"success" => true} =
               rpc(conn, "interrupt_turn", %{
                 "input" => %{"threadId" => thread_id, "kernelTurnId" => kernel_turn_id}
               })

      assert %{"success" => false, "errors" => [%{"fields" => ["kernelTurnId"]}]} =
               rpc(conn, "interrupt_turn", %{
                 "input" => %{"threadId" => thread_id, "kernelTurnId" => kernel_turn_id}
               })

      thread_idle(conn, project["id"], thread_id)

      # the composer's attachments: images ride along as data urls
      assert %{"success" => true, "data" => %{"userText" => "say look"}} =
               rpc(conn, "send_message", %{
                 "fields" => ["userText"],
                 "input" => %{
                   "threadId" => thread_id,
                   "text" => "say look",
                   "images" => ["data:image/png;base64,iVBORw0KGgo="]
                 }
               })

      thread_idle(conn, project["id"], thread_id)

      # the composer's reasoning level: on the turn and remembered by the thread
      assert %{"success" => true, "data" => %{"reasoningEffort" => "low"}} =
               rpc(conn, "send_message", %{
                 "fields" => ["reasoningEffort"],
                 "input" => %{"threadId" => thread_id, "text" => "say low", "effort" => "low"}
               })

      thread_idle(conn, project["id"], thread_id)

      assert %{"success" => true, "data" => [%{"reasoningEffort" => "low", "status" => "idle"}]} =
               rpc(conn, "list_threads", %{
                 "fields" => ["reasoningEffort", "status"],
                 "input" => %{"projectId" => project["id"]}
               })

      # a level the model does not offer is an error on `effort`
      assert %{"success" => false, "errors" => [%{"fields" => ["effort"], "message" => message}]} =
               rpc(conn, "send_message", %{
                 "fields" => ["id"],
                 "input" => %{"threadId" => thread_id, "text" => "say", "effort" => "ultra"}
               })

      assert message =~ "ultra"

      assert %{"success" => true} =
               rpc(conn, "compact_thread", %{"input" => %{"threadId" => thread_id}})

      # a thread's sub-agents are listed under it, never in the project list
      child =
        Projects.create_thread!(%{
          project_id: project["id"],
          kernel_thread_id: "#{kernel_id}-alpha",
          parent_thread_id: thread_id,
          agent_path: "/root/alpha",
          title: "alpha",
          cwd: dir,
          status: :active
        })

      assert %{"success" => true, "data" => [%{"id" => child_id, "agentPath" => "/root/alpha"}]} =
               rpc(conn, "list_subagents", %{
                 "fields" => ["id", "agentPath", "status"],
                 "input" => %{"parentThreadId" => thread_id}
               })

      assert child_id == child.id

      assert %{"success" => true, "data" => [%{"id" => ^thread_id}]} =
               rpc(conn, "list_threads", %{
                 "fields" => ["id"],
                 "input" => %{"projectId" => project["id"]}
               })

      assert %{
               "success" => true,
               "data" => [%{"id" => ^turn_id, "status" => "interrupted"}, _, _]
             } =
               rpc(conn, "list_turns", %{
                 "fields" => ["id", "userText", "status"],
                 "input" => %{"threadId" => thread_id}
               })

      # the composer's @ mentions
      File.write!(Path.join(dir, "notes.md"), "")

      assert %{"success" => true, "data" => [%{"path" => "notes.md", "fileName" => "notes.md"}]} =
               rpc(conn, "search_files", %{
                 "fields" => ["path", "fileName", "matchType"],
                 "input" => %{"id" => project["id"], "query" => "nts"}
               })

      # rename / archive / get
      assert %{"success" => true, "data" => %{"title" => "Named"}} =
               rpc(conn, "rename_thread", %{
                 "fields" => ["title"],
                 "identity" => thread_id,
                 "input" => %{"title" => "Named"}
               })

      assert %{"success" => true, "data" => %{"title" => "Named"}} =
               rpc(conn, "get_thread", %{"fields" => ["title"], "input" => %{"id" => thread_id}})
    end

    test "steer_turn: a message while a turn runs goes into it; nothing running is not_running on threadId",
         %{conn: conn, dir: dir, bypass: bypass} do
      # the steered message is shown at the next step: the model is asked once more
      script!(bypass, [
        held(ResponsesFixture.assistant_message("one")),
        ResponsesFixture.assistant_message("two")
      ])

      project = create!(conn, dir)
      {thread_id, kernel_id} = start!(conn, project)
      :ok = ThreadState.subscribe(kernel_id)

      %{"success" => true, "data" => %{"kernelTurnId" => turn_id}} =
        rpc(conn, "send_message", %{
          "fields" => ["kernelTurnId"],
          "input" => %{"threadId" => thread_id, "text" => "first"}
        })

      assert_receive {:held, h}, 5_000

      assert %{"success" => true, "data" => %{"kernelTurnId" => ^turn_id}} =
               rpc(conn, "steer_turn", %{
                 "fields" => ["kernelTurnId"],
                 "input" => %{"threadId" => thread_id, "text" => "还有这个"}
               })

      # a second send while running is refused on threadId — the client steers
      assert %{"success" => false, "errors" => [%{"fields" => ["threadId"]}]} =
               rpc(conn, "send_message", %{
                 "fields" => ["id"],
                 "input" => %{"threadId" => thread_id, "text" => "again"}
               })

      send(h, :go)
      assert_receive {:thread, _, "turn/completed", %{"turn" => %{"id" => ^turn_id}}}, 5_000
      thread_idle(conn, project["id"], thread_id)

      assert %{
               "success" => false,
               "errors" => [%{"fields" => ["threadId"], "message" => "not_running"}]
             } =
               rpc(conn, "steer_turn", %{
                 "fields" => ["kernelTurnId"],
                 "input" => %{"threadId" => thread_id, "text" => "late"}
               })
    end

    test "retract_turn stops a turn nothing came back for and hands the text back", %{
      conn: conn,
      dir: dir,
      bypass: bypass
    } do
      script!(bypass, [held(ResponsesFixture.assistant_message("one"))])
      project = create!(conn, dir)
      {thread_id, _kernel_id} = start!(conn, project)

      %{"success" => true, "data" => %{"kernelTurnId" => turn_id}} =
        rpc(conn, "send_message", %{
          "fields" => ["kernelTurnId"],
          "input" => %{"threadId" => thread_id, "text" => "wait"}
        })

      assert_receive {:held, _}, 5_000
      Bypass.pass(bypass)

      assert %{"success" => true, "data" => %{"text" => "wait"}} =
               rpc(conn, "retract_turn", %{
                 "fields" => ["text"],
                 "input" => %{"threadId" => thread_id, "kernelTurnId" => turn_id}
               })

      assert %{
               "success" => false,
               "errors" => [%{"fields" => ["kernelTurnId"], "message" => "not_running"}]
             } =
               rpc(conn, "retract_turn", %{
                 "fields" => ["text"],
                 "input" => %{"threadId" => thread_id, "kernelTurnId" => turn_id}
               })

      assert %{"success" => true, "data" => []} =
               rpc(conn, "list_turns", %{
                 "fields" => ["id"],
                 "input" => %{"threadId" => thread_id}
               })
    end

    test "release_waiting sends a waiting message in now; one no longer waiting is an error on waitingId",
         %{conn: conn, dir: dir, bypass: bypass} do
      script!(bypass, [
        held(ResponsesFixture.assistant_message("one")),
        ResponsesFixture.assistant_message("two")
      ])

      project = create!(conn, dir)
      {thread_id, kernel_id} = start!(conn, project)

      %{"success" => true} =
        rpc(conn, "send_message", %{
          "fields" => ["kernelTurnId"],
          "input" => %{"threadId" => thread_id, "text" => "work"}
        })

      assert_receive {:held, handler}, 5_000
      # the view is written by a cast: the list shows a moment later
      :ok = ThreadState.subscribe(kernel_id)
      {:ok, %{pending: true}} = Longx.Agent.send(kernel_id, "news", from: "coder")

      assert_receive {:thread, _, "thread/waiting/updated", %{"waiting" => [%{"id" => wid}]}},
                     5_000

      assert %{"success" => true} =
               rpc(conn, "release_waiting", %{
                 "input" => %{"threadId" => thread_id, "waitingId" => wid}
               })

      assert %{
               "success" => false,
               "errors" => [%{"fields" => ["waitingId"], "message" => "not_found"}]
             } =
               rpc(conn, "release_waiting", %{
                 "input" => %{"threadId" => thread_id, "waitingId" => wid}
               })

      send(handler, :go)
    end

    test "list_recent_threads: every project's conversations, newest activity first, for ⌘K",
         %{conn: conn, dir: dir} do
      other = Path.join(dir, "other")
      File.mkdir_p!(other)
      shut = Path.join(dir, "shut")
      File.mkdir_p!(shut)
      a = Projects.create_project!(%{name: "Alpha", root_path: dir})
      b = Projects.create_project!(%{name: "Beta", root_path: other})
      gone = Projects.create_project!(%{name: "Gone", root_path: shut})

      thread = fn project, n, title ->
        t =
          Projects.create_thread!(%{
            project_id: project.id,
            kernel_thread_id: "native_recent_#{n}",
            cwd: project.root_path,
            title: title
          })

        Projects.touch_thread!(t, %{
          last_activity_at: DateTime.add(~U[2026-09-28 00:00:00Z], n, :minute)
        })
      end

      old = thread.(a, 1, "old one")
      newest = thread.(b, 3, "newest")
      middle = thread.(a, 2, "middle")
      archived = thread.(a, 4, "archived")
      Projects.archive_thread!(archived)
      in_gone = thread.(gone, 5, "in an archived project")
      Projects.archive_project!(gone)

      # a sub-agent's row is no conversation of its own
      Projects.create_thread!(%{
        project_id: a.id,
        kernel_thread_id: "native_recent_child",
        cwd: dir,
        parent_thread_id: middle.id,
        agent_path: "/root/helper"
      })

      assert %{"success" => true, "data" => %{"threads" => threads}} =
               rpc(conn, "list_recent_threads", %{"fields" => ["threads"]})

      assert Enum.map(threads, & &1["id"]) == [newest.id, middle.id, old.id]
      refute Enum.any?(threads, &(&1["id"] in [archived.id, in_gone.id]))

      assert %{
               "title" => "newest",
               "projectSlug" => slug,
               "projectName" => "Beta",
               "lastActivityAt" => at
             } = hd(threads)

      assert slug == b.slug
      assert is_binary(at)

      assert %{"success" => true, "data" => %{"threads" => [only]}} =
               rpc(conn, "list_recent_threads", %{
                 "fields" => ["threads"],
                 "input" => %{"limit" => 1}
               })

      assert only["id"] == newest.id
    end

    test "list_running_threads and answer_request: a thread waiting on the person, then answered",
         %{conn: conn, dir: dir, bypass: bypass} do
      File.mkdir_p!(Path.join(dir, ".longx/local/plugs"))

      File.write!(Path.join(dir, ".longx/local/plugs/login.exs"), """
      defmodule Login do
        use Longx.Agent.Plug

        tool :login, "signs the person in" do
        end

        def login(_args, ctx) do
          case Context.ask(ctx, title: "登录", text: "去登录") do
            {:ok, answer} -> {:ok, "answered " <> Jason.encode!(answer)}
            {:error, why} -> {:error, "no: \#{why}"}
          end
        end
      end
      """)

      File.write!(
        Path.join(dir, ".longx/local/agent.exs"),
        "import Longx.Agent.Config\nagent do\n  plug Login\nend\n"
      )

      script!(bypass, [
        ResponsesFixture.function_call("login", nil, %{}),
        ResponsesFixture.assistant_message("done")
      ])

      project = create!(conn, dir)

      assert %{"success" => true, "data" => %{"threads" => []}} =
               rpc(conn, "list_running_threads", %{"fields" => ["threads"]})

      {thread_id, kernel_id} = start!(conn, project)
      :ok = ThreadState.subscribe(kernel_id)

      %{"success" => true} =
        rpc(conn, "send_message", %{
          "fields" => ["id"],
          "input" => %{"threadId" => thread_id, "text" => "log me in"}
        })

      assert_receive {:thread, _, "longx/action/request", %{"requestId" => request_id}}, 5_000

      assert_eventually(fn -> Ash.get!(Projects.Thread, thread_id).preview == "log me in" end)

      # what the model writes rides on the row: a string-keyed map inside an
      # atom-keyed one (the camelizer once called Atom.to_string on "bytes" —
      # every list_running_threads while a model wrote arguments, Sentry LONX-K)
      :ok =
        ThreadState.ingest(kernel_id, "turn/progress", %{
          "threadId" => kernel_id,
          "progress" => %{"kind" => "toolCall", "name" => "apply_patch", "bytes" => 12}
        })

      assert_receive {:thread, _, "turn/progress", _}, 5_000

      assert %{"success" => true, "data" => %{"threads" => [running]}} =
               rpc(conn, "list_running_threads", %{"fields" => ["threads"]})

      assert running["id"] == thread_id
      assert running["projectSlug"] == project["slug"]
      assert running["projectName"] == "Demo App"
      assert running["preview"] == "log me in"
      assert running["waiting"] == true
      assert is_binary(running["lastActivityAt"])

      assert running["progress"] == %{
               "kind" => "toolCall",
               "name" => "apply_patch",
               "bytes" => 12
             }

      assert is_number(running["turnStartedAt"])

      assert %{"success" => true} =
               rpc(conn, "answer_request", %{
                 "input" => %{
                   "threadId" => thread_id,
                   "requestId" => request_id,
                   "answers" => %{"done" => true}
                 }
               })

      assert_receive {:thread, _, "turn/completed", _}, 5_000
      thread_idle(conn, project["id"], thread_id)

      # done: off the running list, on the finished one (the way back to it)
      assert %{"success" => true, "data" => %{"threads" => [], "finished" => [finished]}} =
               rpc(conn, "list_running_threads", %{"fields" => ["threads", "finished"]})

      assert finished["id"] == thread_id
      assert finished["outcome"] == "completed"
      assert finished["projectSlug"] == project["slug"]
      assert is_number(finished["finishedAt"])
    end

    test "set_goal / clear_goal", %{conn: conn, dir: dir} do
      project = create!(conn, dir)
      {thread_id, kernel_id} = start!(conn, project)
      :ok = ThreadState.subscribe(kernel_id)

      # paused: an active goal on an idle thread starts a turn, and no model plays here
      assert %{
               "success" => true,
               "data" => %{"objective" => "ship it", "status" => "paused", "tokenBudget" => 100}
             } =
               rpc(conn, "set_goal", %{
                 "fields" => ["objective", "status", "tokenBudget", "tokensUsed"],
                 "input" => %{
                   "threadId" => thread_id,
                   "objective" => "ship it",
                   "tokenBudget" => 100,
                   "status" => "paused"
                 }
               })

      assert_receive {:thread, _, "thread/goal/updated", _}, 5_000

      assert %{"success" => true, "data" => %{"status" => "blocked"}} =
               rpc(conn, "set_goal", %{
                 "fields" => ["status"],
                 "input" => %{"threadId" => thread_id, "status" => "blocked"}
               })

      assert %{"success" => true, "data" => %{"cleared" => true}} =
               rpc(conn, "clear_goal", %{
                 "fields" => ["cleared"],
                 "input" => %{"threadId" => thread_id}
               })

      assert %{"success" => true, "data" => %{"cleared" => false}} =
               rpc(conn, "clear_goal", %{
                 "fields" => ["cleared"],
                 "input" => %{"threadId" => thread_id}
               })
    end
  end

  describe "history" do
    test "delete_thread removes the row and its turns, not while a turn runs", %{
      conn: conn,
      dir: dir,
      bypass: bypass
    } do
      script!(bypass, [held(ResponsesFixture.assistant_message("x"))])
      project = create!(conn, dir)
      {thread_id, _} = start!(conn, project)

      %{"success" => true} =
        rpc(conn, "send_message", %{
          "fields" => ["id"],
          "input" => %{"threadId" => thread_id, "text" => "say x"}
        })

      assert_receive {:held, h}, 5_000

      # not while the turn runs
      assert %{"success" => false, "errors" => [%{"fields" => ["threadId"]}]} =
               rpc(conn, "delete_thread", %{"input" => %{"threadId" => thread_id}})

      send(h, :go)
      thread_idle(conn, project["id"], thread_id)

      assert %{"success" => true} =
               rpc(conn, "delete_thread", %{"input" => %{"threadId" => thread_id}})

      assert %{"success" => true, "data" => []} =
               rpc(conn, "list_threads", %{
                 "fields" => ["id"],
                 "input" => %{"projectId" => project["id"]}
               })

      assert Ash.read!(Projects.Turn) |> Enum.reject(&(&1.thread_id != thread_id)) == []
    end
  end

  describe "dirty tree" do
    test "send_message on a dirty tree just sends: no policy, no commit, no dirty argument", %{
      conn: conn,
      dir: dir,
      bypass: bypass
    } do
      script!(bypass, [ResponsesFixture.assistant_message("go")])
      project = create!(conn, dir, %{"initGit" => true})
      File.write!(Path.join(dir, "a.txt"), "changed")
      {thread_id, _} = start!(conn, project)

      assert %{"success" => true} =
               rpc(conn, "send_message", %{
                 "fields" => ["id"],
                 "input" => %{"threadId" => thread_id, "text" => "go"}
               })

      thread_idle(conn, project["id"], thread_id)
      assert File.read!(Path.join(dir, "a.txt")) == "changed"

      # the bookmarks are gone from the schema: a document naming one does not even build
      assert_raise RuntimeError, ~r/no field commitBefore on Turn/, fn ->
        rpc(conn, "list_turns", %{
          "fields" => ["commitBefore"],
          "input" => %{"threadId" => thread_id}
        })
      end
    end
  end

  describe "system" do
    test "list_directory drives the directory picker", %{conn: conn, dir: dir} do
      File.mkdir_p!(Path.join(dir, "child/.git"))

      assert %{"success" => true, "data" => data} =
               rpc(conn, "list_directory", %{
                 "fields" => ["path", "parent", "git", "entries", "roots"],
                 "input" => %{"path" => dir}
               })

      assert data["path"] == dir
      assert [%{"name" => "child", "git" => true, "path" => child}] = data["entries"]
      assert child == Path.join(dir, "child")
      assert Enum.any?(data["roots"], &(&1["path"] == "/"))

      assert %{"success" => false, "errors" => [%{"fields" => ["path"]}]} =
               rpc(conn, "list_directory", %{"fields" => ["path"], "input" => %{"path" => "nope"}})

      # the picker's "new directory"
      assert %{"success" => true, "data" => %{"name" => "fresh", "path" => fresh, "git" => false}} =
               rpc(conn, "create_directory", %{
                 "fields" => ["name", "path", "git"],
                 "input" => %{"parent" => dir, "name" => "fresh"}
               })

      assert fresh == Path.join(dir, "fresh") and File.dir?(fresh)

      assert %{"success" => false, "errors" => [%{"fields" => ["name"]}]} =
               rpc(conn, "create_directory", %{
                 "fields" => ["path"],
                 "input" => %{"parent" => dir, "name" => "fresh"}
               })
    end

    test "create_project with initGit sets git up", %{conn: conn, dir: dir} do
      assert %{"success" => true, "data" => %{"id" => id}} =
               rpc(conn, "create_project", %{
                 "fields" => ["id"],
                 "input" => %{"name" => "Init", "rootPath" => dir, "initGit" => true}
               })

      assert %{"success" => true, "data" => %{"repository" => true}} =
               rpc(conn, "git_info", %{"fields" => ["repository"], "input" => %{"id" => id}})
    end
  end
end
