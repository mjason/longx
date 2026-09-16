defmodule LongxWeb.ProjectsRpcTest do
  @moduledoc """
  The typed RPC surface the SPA uses (`POST /rpc/run`, ash_typescript):
  projects, their git and codex, threads and turns. Exercised at the wire
  so the generated client's contract is what is tested.
  """
  use LongxWeb.ConnCase, async: false

  alias Longx.Projects

  setup do
    Ash.bulk_destroy!(Projects.Turn, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(Projects.Thread, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(Projects.Project, :destroy, %{}, authorize?: false)
    dir = Path.join(System.tmp_dir!(), "longx-rpc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp rpc(conn, action, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/rpc/run", Jason.encode!(Map.put(params, "action", action)))
    |> json_response(200)
  end

  defp create!(conn, dir, extra \\ %{}) do
    %{"success" => true, "data" => project} =
      rpc(conn, "create_project", %{
        "fields" => ["id", "slug", "name", "rootPath", "sandbox", "networkAccess"],
        "input" => Map.merge(%{"name" => "Demo App", "rootPath" => dir}, extra)
      })

    project
  end

  describe "projects" do
    test "create → list → get by slug → update → archive", %{conn: conn, dir: dir} do
      project = create!(conn, dir)
      assert project["slug"] == "demo-app"
      assert project["rootPath"] == Path.expand(dir)
      assert project["sandbox"] == "workspace_write"

      assert %{"success" => true, "data" => [%{"id" => id}]} =
               rpc(conn, "list_projects", %{"fields" => ["id"]})

      assert id == project["id"]

      assert %{"success" => true, "data" => %{"name" => "Demo App"}} =
               rpc(conn, "get_project", %{
                 "fields" => ["name"],
                 "input" => %{"slug" => "demo-app"}
               })

      assert %{"success" => true, "data" => %{"sandbox" => "read_only"}} =
               rpc(conn, "update_project", %{
                 "fields" => ["sandbox"],
                 "identity" => id,
                 "input" => %{"sandbox" => "read_only"}
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

    test "the codex home can be cleared of its memories or reset whole", %{conn: conn, dir: dir} do
      project = create!(conn, dir)
      home = Longx.Codex.Pool.home_dir(project["id"])
      File.mkdir_p!(Path.join(home, "memories"))
      File.write!(Path.join(home, "memories/MEMORY.md"), "x")
      File.write!(Path.join(home, "config.toml"), "# ours")

      assert %{"success" => true} =
               rpc(conn, "clear_codex_memories", %{"input" => %{"id" => project["id"]}})

      refute File.exists?(Path.join(home, "memories"))
      assert File.exists?(Path.join(home, "config.toml"))

      assert %{"success" => true} =
               rpc(conn, "reset_codex_home", %{"input" => %{"id" => project["id"]}})

      refute File.exists?(home)
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

  describe "codex" do
    test "codex_info for a project whose codex never ran", %{conn: conn, dir: dir} do
      project = create!(conn, dir)

      assert %{"success" => true, "data" => %{"exists" => false, "bytes" => 0, "worker" => nil}} =
               rpc(conn, "codex_info", %{
                 "fields" => ["home", "exists", "bytes", "files", "worker"],
                 "input" => %{"id" => project["id"]}
               })
    end

    test "start_thread → send_message → list_threads/list_turns, then stop_codex", %{
      conn: conn,
      dir: dir
    } do
      project = create!(conn, dir)
      on_exit(fn -> Longx.Test.PoolHelpers.stop_pool!([project["id"]]) end)

      assert %{"success" => true, "data" => %{"id" => thread_id, "codexThreadId" => codex_id}} =
               rpc(conn, "start_thread", %{
                 "fields" => ["id", "codexThreadId", "status"],
                 "input" => %{"projectId" => project["id"]}
               })

      assert codex_id =~ ~r/^thr_/

      assert %{"success" => true, "data" => %{"id" => turn_id, "status" => "in_progress"}} =
               rpc(conn, "send_message", %{
                 "fields" => ["id", "status", "userText"],
                 "input" => %{"threadId" => thread_id, "text" => "say hi"}
               })

      # the turn in flight can be stopped from the composer; a stale id is an error, not a crash
      %{"success" => true, "data" => [%{"codexTurnId" => codex_turn_id}]} =
        rpc(conn, "list_turns", %{
          "fields" => ["codexTurnId"],
          "input" => %{"threadId" => thread_id}
        })

      assert %{"success" => true} =
               rpc(conn, "interrupt_turn", %{
                 "input" => %{"threadId" => thread_id, "codexTurnId" => codex_turn_id}
               })

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
      Longx.AI.update_model!(Longx.AI.default_model!(), %{
        reasoning_levels: ["low", "high"],
        reasoning_effort: "high"
      })

      assert %{"success" => true, "data" => %{"reasoningEffort" => "low"}} =
               rpc(conn, "send_message", %{
                 "fields" => ["reasoningEffort"],
                 "input" => %{"threadId" => thread_id, "text" => "say low", "effort" => "low"}
               })

      thread_idle(conn, project["id"], thread_id)

      assert %{"success" => true, "data" => [%{"reasoningEffort" => "low"}]} =
               rpc(conn, "list_threads", %{
                 "fields" => ["reasoningEffort"],
                 "input" => %{"projectId" => project["id"]}
               })

      # a level the model does not offer is an error on `effort`
      assert %{"success" => false, "errors" => [%{"fields" => ["effort"], "message" => message}]} =
               rpc(conn, "send_message", %{
                 "fields" => ["id"],
                 "input" => %{"threadId" => thread_id, "text" => "say", "effort" => "ultra"}
               })

      assert message =~ "ultra"

      # the slash commands: /compact and /review
      assert %{"success" => true} =
               rpc(conn, "compact_thread", %{"input" => %{"threadId" => thread_id}})

      assert %{"success" => true, "data" => %{"userText" => "/review", "status" => "in_progress"}} =
               rpc(conn, "review_thread", %{
                 "fields" => ["userText", "status"],
                 "input" => %{"threadId" => thread_id, "target" => "uncommitted"}
               })

      thread_idle(conn, project["id"], thread_id)

      assert %{"success" => true, "data" => [%{"id" => ^thread_id}]} =
               rpc(conn, "list_threads", %{
                 "fields" => ["id"],
                 "input" => %{"projectId" => project["id"]}
               })

      # a thread's sub-agents (codex-spawned children) are listed under it, never in the project list
      child =
        Longx.Projects.create_thread!(%{
          project_id: project["id"],
          codex_thread_id: "#{codex_id}-alpha",
          parent_thread_id: thread_id,
          agent_path: "/root/alpha",
          title: "alpha",
          cwd: dir,
          sandbox: :workspace_write,
          approval_policy: :on_request,
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

      # the first message, the one with the image, the low one, the review
      assert %{
               "success" => true,
               "data" => [%{"id" => ^turn_id}, _, _, %{"userText" => "/review"}]
             } =
               rpc(conn, "list_turns", %{
                 "fields" => ["id", "userText"],
                 "input" => %{"threadId" => thread_id}
               })

      assert %{"success" => true, "data" => %{"worker" => %{"phase" => "ready"}}} =
               rpc(conn, "codex_info", %{
                 "fields" => ["worker"],
                 "input" => %{"id" => project["id"]}
               })

      # the composer's @ mentions come from codex's file index
      File.write!(Path.join(dir, "notes.md"), "")

      assert %{"success" => true, "data" => [%{"path" => "notes.md", "fileName" => "notes.md"}]} =
               rpc(conn, "search_files", %{
                 "fields" => ["path", "fileName", "matchType"],
                 "input" => %{"id" => project["id"], "query" => "nts"}
               })

      # Settings → codex 进程: every running codex across projects, with what
      # it costs and when it was last used (the idle reaper's clock)
      assert %{"success" => true, "data" => %{"processes" => processes, "idleAfterMs" => idle}} =
               rpc(conn, "list_codex_processes", %{"fields" => ["processes", "idleAfterMs"]})

      assert is_integer(idle)
      pid = project["id"]

      assert [
               %{
                 "projectId" => ^pid,
                 "name" => "Demo App",
                 "slug" => slug,
                 "osPid" => os_pid,
                 "turns" => turns,
                 "activeTurns" => 0,
                 "lastTurnAt" => last,
                 "startedAt" => started,
                 "threads" => 1
               }
             ] =
               Enum.filter(processes, &(&1["projectId"] == pid))

      assert slug == project["slug"] and is_integer(os_pid) and turns >= 4
      assert is_binary(last) and is_binary(started)

      assert %{"success" => true} =
               rpc(conn, "stop_codex", %{"input" => %{"id" => project["id"], "force" => true}})

      assert %{"success" => true, "data" => %{"worker" => nil}} =
               rpc(conn, "codex_info", %{
                 "fields" => ["worker"],
                 "input" => %{"id" => project["id"]}
               })

      assert %{"success" => true, "data" => %{"processes" => processes}} =
               rpc(conn, "list_codex_processes", %{"fields" => ["processes"]})

      refute Enum.any?(processes, &(&1["projectId"] == pid))
    end
  end

  describe "approvals" do
    test "respond answers codex's (integer) request id given as the string the client has", %{
      conn: conn,
      dir: dir
    } do
      project = create!(conn, dir)
      on_exit(fn -> Longx.Test.PoolHelpers.stop_pool!([project["id"]]) end)

      %{"success" => true, "data" => %{"id" => thread_id, "codexThreadId" => codex_id}} =
        rpc(conn, "start_thread", %{
          "fields" => ["id", "codexThreadId"],
          "input" => %{"projectId" => project["id"]}
        })

      :ok = Longx.Codex.Thread.subscribe(codex_id)

      %{"success" => true} =
        rpc(conn, "send_message", %{
          "fields" => ["id"],
          "input" => %{"threadId" => thread_id, "text" => "approve make"}
        })

      assert_receive {:codex, _, "item/commandExecution/requestApproval",
                      %{"requestId" => request_id}},
                     10_000

      assert is_integer(request_id)

      assert %{"success" => true} =
               rpc(conn, "respond", %{
                 "input" => %{
                   "threadId" => thread_id,
                   "requestId" => Integer.to_string(request_id),
                   "decision" => "accept"
                 }
               })

      assert_receive {:codex, _, "serverRequest/resolved", %{"requestId" => ^request_id}}, 5_000
      assert_receive {:codex, _, "turn/completed", _}, 10_000

      # answering twice (or a stale id) is an error, not a crash
      assert %{"success" => false} =
               rpc(conn, "respond", %{
                 "input" => %{
                   "threadId" => thread_id,
                   "requestId" => Integer.to_string(request_id),
                   "decision" => "accept"
                 }
               })
    end
  end

  describe "running threads" do
    test "list_running_threads: every thread with a turn in flight, its project, and whether it waits on the person",
         %{
           conn: conn,
           dir: dir
         } do
      project = create!(conn, dir)
      on_exit(fn -> Longx.Test.PoolHelpers.stop_pool!([project["id"]]) end)

      assert %{"success" => true, "data" => %{"threads" => []}} =
               rpc(conn, "list_running_threads", %{"fields" => ["threads"]})

      %{"success" => true, "data" => %{"id" => thread_id, "codexThreadId" => codex_id}} =
        rpc(conn, "start_thread", %{
          "fields" => ["id", "codexThreadId"],
          "input" => %{"projectId" => project["id"]}
        })

      :ok = Longx.Codex.Thread.subscribe(codex_id)

      %{"success" => true} =
        rpc(conn, "send_message", %{
          "fields" => ["id"],
          "input" => %{"threadId" => thread_id, "text" => "approve make"}
        })

      assert_receive {:codex, _, "item/commandExecution/requestApproval", _}, 10_000

      assert %{"success" => true, "data" => %{"threads" => [running]}} =
               rpc(conn, "list_running_threads", %{"fields" => ["threads"]})

      assert running["id"] == thread_id
      assert running["projectSlug"] == project["slug"]
      assert running["projectName"] == "Demo App"
      assert running["preview"] == "approve make"
      assert running["waiting"] == true
      assert is_binary(running["lastActivityAt"])
    end
  end

  describe "questions" do
    test "answer_request answers codex's requestUserInput with the answers map", %{
      conn: conn,
      dir: dir
    } do
      project = create!(conn, dir)
      on_exit(fn -> Longx.Test.PoolHelpers.stop_pool!([project["id"]]) end)

      %{"success" => true, "data" => %{"id" => thread_id, "codexThreadId" => codex_id}} =
        rpc(conn, "start_thread", %{
          "fields" => ["id", "codexThreadId"],
          "input" => %{"projectId" => project["id"]}
        })

      :ok = Longx.Codex.Thread.subscribe(codex_id)

      %{"success" => true} =
        rpc(conn, "send_message", %{
          "fields" => ["id"],
          "input" => %{"threadId" => thread_id, "text" => "ask which db?"}
        })

      assert_receive {:codex, _, "item/tool/requestUserInput",
                      %{"requestId" => request_id, "questions" => [%{"id" => "q1"}]}},
                     10_000

      assert %{"success" => true} =
               rpc(conn, "answer_request", %{
                 "input" => %{
                   "threadId" => thread_id,
                   "requestId" => Integer.to_string(request_id),
                   "answers" => %{"q1" => %{"answers" => ["sqlite"]}}
                 }
               })

      assert_receive {:codex, _, "serverRequest/resolved", %{"requestId" => ^request_id}}, 5_000
      assert_receive {:codex, _, "turn/completed", _}, 10_000

      assert Enum.any?(
               Longx.Codex.Thread.snapshot(codex_id).items,
               &(&1["type"] == "agentMessage" and &1["text"] =~ "you said sqlite")
             )
    end
  end

  describe "retracting a turn" do
    test "retract_turn stops a turn nothing came back for and hands the text back; a turn with output says has_output",
         %{
           conn: conn,
           dir: dir
         } do
      project = create!(conn, dir)
      on_exit(fn -> Longx.Test.PoolHelpers.stop_pool!([project["id"]]) end)

      %{"success" => true, "data" => %{"id" => thread_id, "codexThreadId" => codex_id}} =
        rpc(conn, "start_thread", %{
          "fields" => ["id", "codexThreadId"],
          "input" => %{"projectId" => project["id"]}
        })

      :ok = Longx.Codex.Thread.subscribe(codex_id)

      %{"success" => true, "data" => %{"codexTurnId" => turn_id}} =
        rpc(conn, "send_message", %{
          "fields" => ["codexTurnId"],
          "input" => %{"threadId" => thread_id, "text" => "wait"}
        })

      assert_receive {:codex, _, "item/completed", %{"item" => %{"type" => "userMessage"}}},
                     10_000

      assert %{"success" => true, "data" => %{"text" => "wait"}} =
               rpc(conn, "retract_turn", %{
                 "fields" => ["text"],
                 "input" => %{"threadId" => thread_id, "codexTurnId" => turn_id}
               })

      assert %{
               "success" => false,
               "errors" => [%{"fields" => ["codexTurnId"], "message" => "not_running"}]
             } =
               rpc(conn, "retract_turn", %{
                 "fields" => ["text"],
                 "input" => %{"threadId" => thread_id, "codexTurnId" => turn_id}
               })
    end
  end

  describe "goals and skills" do
    test "set_goal / clear_goal drive codex's goal mode; list_skills names the $-mentionable skills; send_message carries them",
         %{
           conn: conn,
           dir: dir
         } do
      project = create!(conn, dir)
      on_exit(fn -> Longx.Test.PoolHelpers.stop_pool!([project["id"]]) end)

      %{"success" => true, "data" => %{"id" => thread_id, "codexThreadId" => codex_id}} =
        rpc(conn, "start_thread", %{
          "fields" => ["id", "codexThreadId"],
          "input" => %{"projectId" => project["id"]}
        })

      :ok = Longx.Codex.Thread.subscribe(codex_id)

      assert %{
               "success" => true,
               "data" => %{"objective" => "ship", "status" => "active", "tokenBudget" => 2000}
             } =
               rpc(conn, "set_goal", %{
                 "fields" => ["objective", "status", "tokenBudget", "tokensUsed"],
                 "input" => %{
                   "threadId" => thread_id,
                   "objective" => "ship",
                   "tokenBudget" => 2000
                 }
               })

      # a change of status alone keeps the budget; a null budget clears it
      assert %{"success" => true, "data" => %{"status" => "paused", "tokenBudget" => 2000}} =
               rpc(conn, "set_goal", %{
                 "fields" => ["status", "tokenBudget"],
                 "input" => %{"threadId" => thread_id, "status" => "paused"}
               })

      assert %{"success" => true, "data" => %{"tokenBudget" => nil}} =
               rpc(conn, "set_goal", %{
                 "fields" => ["tokenBudget"],
                 "input" => %{"threadId" => thread_id, "tokenBudget" => nil}
               })

      assert %{"success" => true, "data" => %{"cleared" => true}} =
               rpc(conn, "clear_goal", %{
                 "fields" => ["cleared"],
                 "input" => %{"threadId" => thread_id}
               })

      assert %{
               "success" => true,
               "data" => [
                 %{"name" => "review-agent", "path" => _},
                 %{"name" => "docs", "path" => docs}
               ]
             } =
               rpc(conn, "list_skills", %{
                 "fields" => ["name", "description", "shortDescription", "path", "enabled"],
                 "input" => %{"id" => project["id"]}
               })

      assert %{"success" => true} =
               rpc(conn, "send_message", %{
                 "fields" => ["id"],
                 "input" => %{
                   "threadId" => thread_id,
                   "text" => "say hi $docs",
                   "skills" => [%{"name" => "docs", "path" => docs}]
                 }
               })

      assert_receive {:codex, _, "turn/completed", _}, 10_000
      {:ok, pool_conn} = Longx.Codex.Pool.connection(project["id"])

      assert {:ok,
              %{
                "thread" => %{
                  "lastTurnParams" => %{"input" => [_, %{"type" => "skill", "name" => "docs"}]}
                }
              }} =
               Longx.Codex.Connection.request(pool_conn, "thread/read", %{"threadId" => codex_id})
    end
  end

  describe "automatic approval review" do
    test "approve_review overrides a denied review; an unknown id is an error on review_id", %{
      conn: conn,
      dir: dir
    } do
      project = create!(conn, dir)
      on_exit(fn -> Longx.Test.PoolHelpers.stop_pool!([project["id"]]) end)

      %{"success" => true, "data" => %{"id" => thread_id, "codexThreadId" => codex_id}} =
        rpc(conn, "start_thread", %{
          "fields" => ["id", "codexThreadId", "autoReview"],
          "input" => %{"projectId" => project["id"]}
        })

      :ok = Longx.Codex.Thread.subscribe(codex_id)

      Longx.Codex.ThreadState.ingest(codex_id, "item/autoApprovalReview/completed", %{
        "threadId" => codex_id,
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

      assert %{"success" => true} =
               rpc(conn, "approve_review", %{
                 "input" => %{"threadId" => thread_id, "reviewId" => "rev-1"}
               })

      assert_receive {:codex, _, "item/autoApprovalReview/userApproved",
                      %{"reviewId" => "rev-1"}},
                     5_000

      assert %{"success" => false, "errors" => [%{"fields" => ["reviewId"]}]} =
               rpc(conn, "approve_review", %{
                 "input" => %{"threadId" => thread_id, "reviewId" => "rev-9"}
               })
    end
  end

  describe "history" do
    defp turn_status(conn, thread_id, wanted, attempts \\ 100) do
      %{"success" => true, "data" => turns} =
        rpc(conn, "list_turns", %{
          "fields" => ["id", "status", "commitBefore", "commitAfter"],
          "input" => %{"threadId" => thread_id}
        })

      cond do
        Enum.all?(turns, &(&1["status"] == wanted)) and turns != [] ->
          turns

        attempts == 0 ->
          flunk("turns never became #{wanted}: #{inspect(turns)}")

        true ->
          Process.sleep(50)
          turn_status(conn, thread_id, wanted, attempts - 1)
      end
    end

    test "restore_proposal → restore_files → redo_turn over the wire", %{conn: conn, dir: dir} do
      project = create!(conn, dir, %{"initGit" => true})
      on_exit(fn -> Longx.Test.PoolHelpers.stop_pool!([project["id"]]) end)

      %{"success" => true, "data" => %{"id" => thread_id}} =
        rpc(conn, "start_thread", %{
          "fields" => ["id"],
          "input" => %{"projectId" => project["id"]}
        })

      %{"success" => true, "data" => %{"id" => turn_id}} =
        rpc(conn, "send_message", %{
          "fields" => ["id"],
          "input" => %{"threadId" => thread_id, "text" => "say one"}
        })

      [%{"commitBefore" => sha}] = turn_status(conn, thread_id, "completed")
      assert is_binary(sha)

      # some work after the turn, then the proposal names it
      File.write!(Path.join(dir, "a.txt"), "changed")

      assert %{"success" => true, "data" => proposal} =
               rpc(conn, "restore_proposal", %{
                 "fields" => ["commit", "dirtyNow", "changedFiles", "laterTurns"],
                 "input" => %{"turnId" => turn_id}
               })

      assert %{
               "commit" => ^sha,
               "dirtyNow" => true,
               "changedFiles" => ["a.txt"],
               "laterTurns" => 0
             } =
               proposal

      # restoring needs confirm, makes the safety commit, puts a.txt back
      assert %{"success" => false} =
               rpc(conn, "restore_files", %{
                 "fields" => ["head"],
                 "input" => %{"turnId" => turn_id}
               })

      assert %{"success" => true, "data" => %{"safetyCommit" => safety, "head" => head}} =
               rpc(conn, "restore_files", %{
                 "fields" => ["safetyCommit", "head"],
                 "input" => %{"turnId" => turn_id, "confirm" => true}
               })

      assert is_binary(safety) and is_binary(head)
      refute File.exists?(Path.join(dir, "a.txt"))

      # redo from that turn with other text: the old turn is reverted, a new one runs
      assert %{"success" => true, "data" => %{"id" => new_id, "userText" => "say two"}} =
               rpc(conn, "redo_turn", %{
                 "fields" => ["id", "userText", "status"],
                 "input" => %{"turnId" => turn_id, "text" => "say two", "mode" => "revert"}
               })

      refute new_id == turn_id
      turn_status(conn, thread_id, "completed")

      %{"success" => true, "data" => all} =
        rpc(conn, "list_turns", %{
          "fields" => ["id", "status"],
          "input" => %{"threadId" => thread_id, "includeReverted" => true}
        })

      assert Enum.find(all, &(&1["id"] == turn_id))["status"] == "reverted"
    end
  end

  defp thread_idle(conn, project_id, thread_id, attempts \\ 100) do
    %{"success" => true, "data" => threads} =
      rpc(conn, "list_threads", %{
        "fields" => ["id", "status"],
        "input" => %{"projectId" => project_id}
      })

    case Enum.find(threads, &(&1["id"] == thread_id)) do
      %{"status" => "idle"} ->
        :ok

      _ when attempts > 0 ->
        Process.sleep(50)
        thread_idle(conn, project_id, thread_id, attempts - 1)

      other ->
        flunk("thread never idle: #{inspect(other)}")
    end
  end

  describe "delete thread" do
    test "delete_thread removes the row and its turns; codex's own history is untouched", %{
      conn: conn,
      dir: dir
    } do
      project = create!(conn, dir)
      on_exit(fn -> Longx.Test.PoolHelpers.stop_pool!([project["id"]]) end)

      %{"success" => true, "data" => %{"id" => thread_id}} =
        rpc(conn, "start_thread", %{
          "fields" => ["id"],
          "input" => %{"projectId" => project["id"]}
        })

      %{"success" => true} =
        rpc(conn, "send_message", %{
          "fields" => ["id"],
          "input" => %{"threadId" => thread_id, "text" => "say x"}
        })

      # not while the turn runs
      assert %{"success" => false} =
               rpc(conn, "delete_thread", %{"input" => %{"threadId" => thread_id}})

      thread_idle(conn, project["id"], thread_id)

      assert %{"success" => true} =
               rpc(conn, "delete_thread", %{"input" => %{"threadId" => thread_id}})

      assert %{"success" => true, "data" => []} =
               rpc(conn, "list_threads", %{
                 "fields" => ["id"],
                 "input" => %{"projectId" => project["id"]}
               })

      assert Ash.read!(Longx.Projects.Turn) |> Enum.reject(&(&1.thread_id != thread_id)) == []
    end
  end

  describe "dirty tree" do
    test "send_message on a dirty :ask project is a structured error the UI can act on", %{
      conn: conn,
      dir: dir
    } do
      project = create!(conn, dir, %{"initGit" => true, "dirtyStart" => "ask"})
      on_exit(fn -> Longx.Test.PoolHelpers.stop_pool!([project["id"]]) end)
      File.write!(Path.join(dir, "a.txt"), "changed")

      %{"success" => true, "data" => %{"id" => thread_id}} =
        rpc(conn, "start_thread", %{
          "fields" => ["id"],
          "input" => %{"projectId" => project["id"]}
        })

      assert %{"success" => false, "errors" => [error]} =
               rpc(conn, "send_message", %{
                 "fields" => ["id"],
                 "input" => %{"threadId" => thread_id, "text" => "go"}
               })

      assert %{"type" => "dirty_tree", "details" => %{"changes" => [%{"path" => "a.txt"}]}} =
               error

      # the override goes through
      assert %{"success" => true} =
               rpc(conn, "send_message", %{
                 "fields" => ["id"],
                 "input" => %{"threadId" => thread_id, "text" => "go", "dirty" => "ignore"}
               })
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

    test "sandbox status", %{conn: conn} do
      assert %{"success" => true, "data" => %{"status" => status, "checkedAt" => at}} =
               rpc(conn, "sandbox_status", %{"fields" => ["status", "reason", "checkedAt"]})

      assert status in ["ok", "unavailable"]
      assert is_binary(at)
    end
  end
end
