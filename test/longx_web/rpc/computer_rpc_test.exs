defmodule LongxWeb.ComputerRpcTest do
  use LongxWeb.ConnCase, async: false

  test "service configuration reports only URL and credential presence", %{conn: conn} do
    assert %{"success" => true, "data" => data} =
             rpc(conn, "computer_settings", %{"fields" => ["url", "hasToken"]})

    assert String.ends_with?(data["url"], "/mcp")
    assert is_boolean(data["hasToken"])
    refute Map.has_key?(data, "token")
  end

  test "connection status and disconnect do not expose credentials", %{conn: conn} do
    assert %{"success" => true, "data" => data} =
             rpc(conn, "computer_connection", %{"fields" => ["phase", "foreground", "busy"]})

    assert data["phase"] in ["disconnected", "connecting", "ready"]

    assert %{"success" => true, "data" => %{"phase" => "disconnected"}} =
             rpc(conn, "computer_disconnect", %{"fields" => ["phase"]})
  end

  test "multi-computer configuration and alias mutations are available over RPC", %{conn: conn} do
    token = "rpc-fixture-key-012345678901234567890"

    for {id, name} <- [{"mac", "Mac"}, {"win", "Windows"}] do
      assert %{"success" => true} =
               rpc(conn, "computer_configure", %{
                 "input" => %{
                   "id" => id,
                   "name" => name,
                   "url" => "https://#{id}.example/mcp",
                   "token" => token
                 },
                 "fields" => ["url", "hasToken"]
               })
    end

    assert %{"success" => true, "data" => rows} =
             rpc(conn, "computer_devices", %{
               "fields" => ["id", "name", "url", "hasToken", %{"connection" => ["phase"]}]
             })

    assert Enum.any?(rows, &(&1["id"] == "mac" and &1["hasToken"]))
    refute Jason.encode!(rows) =~ token

    assert %{"success" => true} =
             rpc(conn, "computer_set_alias", %{
               "input" => %{"name" => "qa", "computers" => ["win", "mac"]},
               "fields" => ["default"]
             })

    assert %{"success" => true, "data" => %{"default" => "qa"}} =
             rpc(conn, "computer_set_default", %{
               "input" => %{"name" => "qa"},
               "fields" => ["default"]
             })

    assert %{"success" => true} = rpc(conn, "computer_delete", %{"input" => %{"id" => "win"}})

    assert %{"success" => true, "data" => %{"aliases" => aliases}} =
             rpc(conn, "computer_aliases", %{
               "fields" => [%{"aliases" => ["name", "computers"]}]
             })

    assert Enum.find(aliases, &(&1["name"] == "qa"))["computers"] == ["mac"]
  end

  test "invalid aliases are structured argument errors", %{conn: conn} do
    assert %{"success" => false, "errors" => [_ | _]} =
             rpc(conn, "computer_set_alias", %{
               "input" => %{"name" => "qa", "computers" => ["unknown"]},
               "fields" => ["default"]
             })

    assert %{"success" => false, "errors" => [_ | _]} =
             rpc(conn, "computer_set_default", %{
               "input" => %{"name" => "unknown"},
               "fields" => ["default"]
             })
  end
end
