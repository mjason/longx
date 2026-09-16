defmodule LongxWeb.BrowserRpcTest do
  @moduledoc "The built-in browser's settings on the wire: private addresses allowed or not."
  use LongxWeb.ConnCase, async: false

  defp rpc(conn, action, params \\ %{}) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/rpc/run", Jason.encode!(Map.put(params, "action", action)))
    |> json_response(200)
  end

  test "browser_settings reads the switch; set_browser_private_network flips it", %{conn: conn} do
    Longx.Browser.set_allow_private_network(false)

    assert %{
             "success" => true,
             "data" => %{"allowPrivateNetwork" => false, "available" => available}
           } =
             rpc(conn, "browser_settings", %{"fields" => ["allowPrivateNetwork", "available"]})

    assert is_boolean(available)

    assert %{"success" => true, "data" => %{"allowPrivateNetwork" => true}} =
             rpc(conn, "set_browser_private_network", %{
               "fields" => ["allowPrivateNetwork"],
               "input" => %{"enabled" => true}
             })

    assert Longx.Browser.allow_private_network?()

    assert %{"success" => true, "data" => %{"allowPrivateNetwork" => false}} =
             rpc(conn, "set_browser_private_network", %{
               "fields" => ["allowPrivateNetwork"],
               "input" => %{"enabled" => false}
             })
  end
end
