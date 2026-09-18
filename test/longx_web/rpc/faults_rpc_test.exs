defmodule LongxWeb.FaultsRpcTest do
  @moduledoc "The server's recent faults on the wire (Settings → 请求记录, the status strip)."
  use LongxWeb.ConnCase, async: false

  alias Longx.System.Faults

  defp rpc(conn, action, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/rpc/run", Jason.encode!(Map.put(params, "action", action)))
    |> json_response(200)
  end

  setup do
    Faults.clear()
    on_exit(fn -> Faults.clear() end)
    :ok
  end

  test "recent faults newest first, with the count of the last hour", %{conn: conn} do
    assert %{"success" => true, "data" => %{"faults" => [], "recent" => 0}} =
             rpc(conn, "recent_faults", %{"fields" => ["faults", "recent"]})

    :ok = Faults.record(:socket_encode, "thread:t", "could not encode event: bad bytes")
    :ok = Faults.record(:wire_clean, "thread:u", "snapshot cleaned")

    assert %{"success" => true, "data" => %{"faults" => [first, second], "recent" => 2}} =
             rpc(conn, "recent_faults", %{"fields" => ["faults", "recent"]})

    assert %{"kind" => "wire_clean", "where" => "thread:u", "at" => at} = first
    assert is_binary(at)
    assert %{"kind" => "socket_encode", "detail" => detail} = second
    assert detail =~ "bad bytes"
  end
end
