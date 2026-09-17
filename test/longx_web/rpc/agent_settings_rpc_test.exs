defmodule LongxWeb.AgentSettingsRpcTest do
  @moduledoc "The native kernel's settings and the person's global agent files on the wire."
  use LongxWeb.ConnCase, async: false

  setup do
    Ash.bulk_destroy!(Longx.System.Setting, :destroy, %{}, authorize?: false)
    dir = Path.join(System.tmp_dir!(), "longx-agentrpc-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:longx, Longx.Agent.Loader, [])
    Application.put_env(:longx, Longx.Agent.Loader, Keyword.put(previous, :global_dir, dir))

    on_exit(fn ->
      Application.put_env(:longx, Longx.Agent.Loader, previous)
      Longx.Test.TmpDirs.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  defp rpc(conn, action, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/rpc/run", Jason.encode!(Map.put(params, "action", action)))
    |> json_response(200)
  end

  @fields [
    "maxDepth",
    "maxChildren",
    "idleMinutes",
    "childModel",
    "childEffort",
    "reviewerModel",
    "reviewerEffort"
  ]

  test "read and write the settings; a bad value is an error on its field", %{conn: conn} do
    assert %{
             "success" => true,
             "data" => %{"maxDepth" => 2, "maxChildren" => 4, "idleMinutes" => 30}
           } =
             rpc(conn, "agent_settings", %{"fields" => @fields})

    assert %{"success" => true, "data" => %{"maxDepth" => 3}} =
             rpc(conn, "set_agent_settings", %{"fields" => @fields, "input" => %{"maxDepth" => 3}})

    assert %{"success" => false, "errors" => [%{"fields" => ["maxChildren"]}]} =
             rpc(conn, "set_agent_settings", %{
               "fields" => @fields,
               "input" => %{"maxChildren" => 0}
             })
  end

  test "the global agent files: list, write, read, delete", %{conn: conn, dir: dir} do
    assert %{"success" => true, "data" => []} =
             rpc(conn, "agent_files", %{"fields" => ["path", "size"]})

    text = "import Longx.Agent.Config\nagent do\n  summary \"mine\"\nend\n"

    assert %{"success" => true} =
             rpc(conn, "agent_write_file", %{
               "input" => %{"path" => "agents/mine/agent.exs", "content" => text}
             })

    assert File.read!(Path.join(dir, "agents/mine/agent.exs")) == text

    assert %{"success" => true, "data" => [%{"path" => "agents/mine/agent.exs"}]} =
             rpc(conn, "agent_files", %{"fields" => ["path", "size"]})

    assert %{"success" => true, "data" => %{"text" => ^text}} =
             rpc(conn, "agent_read_file", %{
               "fields" => ["text"],
               "input" => %{"path" => "agents/mine/agent.exs"}
             })

    assert %{"success" => false} =
             rpc(conn, "agent_write_file", %{
               "input" => %{"path" => "../out.exs", "content" => text}
             })

    assert %{"success" => true} =
             rpc(conn, "agent_delete_file", %{"input" => %{"path" => "agents/mine/agent.exs"}})

    refute File.exists?(Path.join(dir, "agents/mine/agent.exs"))
  end
end
