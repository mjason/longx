defmodule LongxWeb.Rpc.WatchesRpcTest do
  @moduledoc "The watches and the directory at the wire: what the settings page and the Agents window call."
  use LongxWeb.ConnCase, async: false

  alias Longx.Projects
  alias Longx.Projects.Thread
  alias Longx.Watches
  alias Longx.Watches.Watch

  setup %{conn: conn} do
    Ash.bulk_destroy!(Watch, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(Thread, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(Projects.Project, :destroy, %{}, authorize?: false)
    n = System.unique_integer([:positive])
    dir = Path.join(System.tmp_dir!(), "longx-watchrpc-#{n}")
    File.mkdir_p!(Path.join(dir, ".longx/local/watches"))

    File.write!(Path.join(dir, ".longx/local/watches/health.exs"), """
    defmodule Health do
      use Longx.Agent.Watch
      every "*/5 * * * *"
      def run(ctx) do
        log(ctx, "fine")
        send(ctx, "main", "hello")
        {:ok, %{}}
      end
    end
    """)

    on_exit(fn ->
      Longx.Test.Agents.stop_all!()
      File.rm_rf!(dir)
    end)

    project = Projects.create_project!(%{name: "WatchRpc #{n}", root_path: dir})
    :ok = Watches.reconcile_project(project)
    %{conn: conn, project: project, dir: dir}
  end

  defp rpc(conn, action, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/rpc/run", Jason.encode!(Map.put(params, "action", action)))
    |> json_response(200)
  end

  @fields ~w(id name path layer kind cron at enabled disabledReason loadError nextDueAt runningSince lastRunAt lastDurationMs lastError lastOutput lastSentTo runs sends webhookToken state)

  test "list, switch, dry run, delete; the global overview", %{conn: conn, project: project} do
    assert %{"success" => true, "data" => [row]} =
             rpc(conn, "list_watches", %{
               "fields" => @fields,
               "input" => %{"projectId" => project.id}
             })

    assert %{"name" => "health", "kind" => "cron", "cron" => "*/5 * * * *", "enabled" => true} =
             row

    assert is_binary(row["nextDueAt"])

    assert %{"success" => true, "data" => %{"enabled" => false, "disabledReason" => "by_person"}} =
             rpc(conn, "switch_watch", %{
               "fields" => @fields,
               "input" => %{"id" => row["id"], "enabled" => false}
             })

    assert %{"success" => true, "data" => %{"enabled" => true, "nextDueAt" => next}} =
             rpc(conn, "switch_watch", %{
               "fields" => @fields,
               "input" => %{"id" => row["id"], "enabled" => true}
             })

    assert is_binary(next)

    assert %{"success" => true, "data" => dry} =
             rpc(conn, "dry_run_watch", %{
               "fields" => ~w(ok result log sends),
               "input" => %{"id" => row["id"]}
             })

    assert %{"ok" => true, "log" => ["fine"], "sends" => [~s("main": hello)]} = dry
    assert dry["result"] =~ "{:ok"

    assert %{"success" => true, "data" => %{"watches" => [all]}} =
             rpc(conn, "list_all_watches", %{"fields" => ~w(watches)})

    assert all["projectName"] == project.name
    assert all["projectSlug"] == project.slug
    assert all["name"] == "health"

    assert %{"success" => true, "data" => true} =
             rpc(conn, "delete_watch", %{"input" => %{"id" => row["id"]}})

    refute File.exists?(row["path"])

    assert %{"success" => true, "data" => []} =
             rpc(conn, "list_watches", %{
               "fields" => @fields,
               "input" => %{"projectId" => project.id}
             })
  end

  test "the directory and a handle set by the person", %{conn: conn, project: project} do
    {:ok, thread} = Projects.start_thread(project)

    assert %{"success" => true, "data" => %{"handle" => "main"}} =
             rpc(conn, "set_thread_handle", %{
               "fields" => ~w(id handle),
               "input" => %{"threadId" => thread.id, "handle" => "main"}
             })

    assert %{"success" => false, "errors" => [error | _]} =
             rpc(conn, "set_thread_handle", %{
               "fields" => ~w(id handle),
               "input" => %{"threadId" => thread.id, "handle" => "Not Ok"}
             })

    assert error["field"] == "handle" or error["message"] =~ "句柄"

    assert %{"success" => true, "data" => %{"sessions" => [session]}} =
             rpc(conn, "directory", %{
               "fields" => ~w(sessions),
               "input" => %{"projectId" => project.id}
             })

    assert %{
             "address" => "main",
             "handle" => "main",
             "state" => "idle",
             "threadId" => id,
             "team" => []
           } = session

    assert id == thread.id
  end
end
