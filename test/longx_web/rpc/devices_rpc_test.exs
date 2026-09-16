defmodule LongxWeb.DevicesRpcTest do
  # Settings → 移动端: a pairing code for the phone, the paired devices, revoke.
  use LongxWeb.ConnCase, async: false

  alias Longx.System

  setup do
    for d <- System.list_devices!(), do: System.revoke_device!(d)
    :ok
  end

  defp rpc(conn, action, params \\ %{}) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/rpc/run", Jason.encode!(Map.put(params, "action", action)))
    |> json_response(200)
  end

  test "pairing_code → pair → list_devices → revoke_device", %{conn: conn} do
    assert %{"success" => true, "data" => %{"code" => code, "expiresAt" => _}} =
             rpc(conn, "pairing_code", %{"fields" => ["code", "expiresAt"]})

    %{"token" => _} =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(
        "/pair",
        Jason.encode!(%{"code" => code, "name" => "Pixel", "platform" => "android"})
      )
      |> json_response(200)

    assert %{
             "success" => true,
             "data" => [%{"id" => id, "name" => "Pixel", "platform" => "android"}]
           } =
             rpc(conn, "list_devices", %{
               "fields" => ["id", "name", "platform", "lastSeenAt", "insertedAt"]
             })

    assert %{"success" => true} = rpc(conn, "revoke_device", %{"identity" => id})
    assert %{"success" => true, "data" => []} = rpc(conn, "list_devices", %{"fields" => ["id"]})
  end
end
