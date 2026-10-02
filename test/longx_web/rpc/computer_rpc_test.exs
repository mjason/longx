defmodule LongxWeb.ComputerRpcTest do
  use LongxWeb.ConnCase, async: false

  test "local Driver status is available over the settings API", %{conn: conn} do
    assert %{"success" => true, "data" => data} =
             rpc(conn, "computer_status", %{
               "fields" => [
                 "stage",
                 "source",
                 "path",
                 "appPath",
                 "latest",
                 "downloadSize",
                 "upgradable"
               ]
             })

    assert data["latest"] == Longx.Computer.Runtime.version()
    assert data["stage"] in ["idle", "installed", "failed"]
    assert is_integer(data["downloadSize"])
    assert is_boolean(data["upgradable"])
    refute Map.has_key?(data, "token")
  end
end
