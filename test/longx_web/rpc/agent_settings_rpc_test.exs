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
    "childEffort"
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
end
