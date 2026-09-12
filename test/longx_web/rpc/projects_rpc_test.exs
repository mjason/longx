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

  describe "system" do
    test "sandbox status", %{conn: conn} do
      assert %{"success" => true, "data" => %{"status" => status, "checkedAt" => at}} =
               rpc(conn, "sandbox_status", %{"fields" => ["status", "reason", "checkedAt"]})

      assert status in ["ok", "unavailable"]
      assert is_binary(at)
    end
  end
end
