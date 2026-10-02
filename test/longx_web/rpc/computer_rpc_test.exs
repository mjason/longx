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
end
