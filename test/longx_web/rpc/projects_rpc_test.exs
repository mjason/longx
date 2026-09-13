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

      assert %{"success" => true, "data" => [%{"id" => ^thread_id}]} =
               rpc(conn, "list_threads", %{
                 "fields" => ["id"],
                 "input" => %{"projectId" => project["id"]}
               })

      assert %{"success" => true, "data" => [%{"id" => ^turn_id}]} =
               rpc(conn, "list_turns", %{
                 "fields" => ["id"],
                 "input" => %{"threadId" => thread_id}
               })

      assert %{"success" => true, "data" => %{"worker" => %{"phase" => "ready"}}} =
               rpc(conn, "codex_info", %{
                 "fields" => ["worker"],
                 "input" => %{"id" => project["id"]}
               })

      assert %{"success" => true} =
               rpc(conn, "stop_codex", %{"input" => %{"id" => project["id"], "force" => true}})

      assert %{"success" => true, "data" => %{"worker" => nil}} =
               rpc(conn, "codex_info", %{
                 "fields" => ["worker"],
                 "input" => %{"id" => project["id"]}
               })
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
