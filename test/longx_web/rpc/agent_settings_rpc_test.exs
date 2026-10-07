defmodule LongxWeb.AgentSettingsRpcTest do
  @moduledoc "The native kernel's settings on the wire."
  use LongxWeb.ConnCase, async: false

  setup do
    Ash.bulk_destroy!(Longx.System.Setting, :destroy, %{}, authorize?: false)
    dir = Path.join(System.tmp_dir!(), "longx-agentrpc-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:longx, Longx.Agent.Knowledge, [])
    Application.put_env(:longx, Longx.Agent.Knowledge, Keyword.put(previous, :global_dir, dir))

    on_exit(fn ->
      Application.put_env(:longx, Longx.Agent.Knowledge, previous)
      Longx.Test.TmpDirs.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  @fields [
    "maxDepth",
    "maxChildren",
    "idleMinutes",
    "childModel",
    "childEffort",
    "extraPath",
    "defaultExtraPath"
  ]

  @tag :cgroup
  test "cgroup mode and read-only status are on the typed RPC and GraphQL wire", %{conn: conn} do
    for mode <- ["auto", "off", "required"] do
      assert %{"success" => true, "data" => %{"commandCgroupMode" => ^mode}} =
               rpc(conn, "set_agent_settings", %{
                 "fields" => ["commandCgroupMode"],
                 "input" => %{"commandCgroupMode" => mode}
               })
    end

    assert %{"success" => false, "errors" => [%{"fields" => ["commandCgroupMode"]}]} =
             rpc(conn, "set_agent_settings", %{
               "fields" => ["commandCgroupMode"],
               "input" => %{"commandCgroupMode" => "always"}
             })

    assert %{"success" => true} =
             rpc(conn, "set_agent_settings", %{
               "fields" => ["commandCgroupMode"],
               "input" => %{"commandCgroupMode" => "off"}
             })

    assert %{"success" => true, "data" => %{"mode" => "off", "capability" => "off"}} =
             rpc(conn, "command_guard_status", %{"fields" => ["mode", "capability", "reason"]})

    assert %{"data" => %{"commandGuardStatus" => %{"mode" => "off", "capability" => "off"}}} =
             conn
             |> post("/gql", %{
               "query" =>
                 "{ commandGuardStatus { mode capability activeTasks cleanupPendingTasks checkedAt } }"
             })
             |> json_response(200)
  end

  @tag :cgroup
  test "GraphQL settings expose typed task budgets and preserve zero swap", %{conn: conn} do
    query = """
    mutation Budgets($input: SetAgentSettingsInput!) {
      setAgentSettings(input: $input) {
        commandMemoryLimitPercent
        commandSwapLimitMb
      }
    }
    """

    assert %{
             "data" => %{
               "setAgentSettings" => %{
                 "commandMemoryLimitPercent" => 50,
                 "commandSwapLimitMb" => 0
               }
             }
           } =
             conn
             |> post("/gql", %{
               "query" => query,
               "variables" => %{
                 "input" => %{"commandMemoryLimitPercent" => 50, "commandSwapLimitMb" => 0}
               }
             })
             |> json_response(200)
  end

  @tag :cgroup
  test "command budgets round trip with zero swap, inheritance and field errors", %{conn: conn} do
    fields = ["commandMemoryLimitPercent", "commandSwapLimitMb"]

    assert %{
             "success" => true,
             "data" => %{"commandMemoryLimitPercent" => 75, "commandSwapLimitMb" => 1024}
           } =
             rpc(conn, "agent_settings", %{"fields" => fields})

    assert %{
             "success" => true,
             "data" => %{"commandMemoryLimitPercent" => 60, "commandSwapLimitMb" => 0}
           } =
             rpc(conn, "set_agent_settings", %{
               "fields" => fields,
               "input" => %{"commandMemoryLimitPercent" => 60, "commandSwapLimitMb" => 0}
             })

    for {field, bad} <- [{"commandMemoryLimitPercent", 81}, {"commandSwapLimitMb", -1}] do
      assert %{"success" => false, "errors" => [%{"fields" => [^field]}]} =
               rpc(conn, "set_agent_settings", %{"fields" => fields, "input" => %{field => bad}})
    end

    assert %{
             "success" => true,
             "data" => %{"commandMemoryLimitPercent" => 75, "commandSwapLimitMb" => 1024}
           } =
             rpc(conn, "set_agent_settings", %{
               "fields" => fields,
               "input" => %{"commandMemoryLimitPercent" => nil, "commandSwapLimitMb" => nil}
             })
  end

  test "read and write the settings; a bad value is an error on its field", %{conn: conn} do
    assert %{
             "success" => true,
             "data" => %{"maxDepth" => 2, "maxChildren" => 4, "idleMinutes" => 30}
           } =
             rpc(conn, "agent_settings", %{"fields" => @fields})

    assert %{"success" => true, "data" => %{"maxDepth" => 3}} =
             rpc(conn, "set_agent_settings", %{"fields" => @fields, "input" => %{"maxDepth" => 3}})

    assert %{"success" => true, "data" => %{"extraPath" => ""}} =
             rpc(conn, "set_agent_settings", %{
               "fields" => @fields,
               "input" => %{"extraPath" => ""}
             })

    assert %{"success" => false, "errors" => [%{"fields" => ["maxChildren"]}]} =
             rpc(conn, "set_agent_settings", %{
               "fields" => @fields,
               "input" => %{"maxChildren" => 0}
             })
  end
end
