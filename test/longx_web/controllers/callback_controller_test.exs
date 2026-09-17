defmodule LongxWeb.CallbackControllerTest do
  use LongxWeb.ConnCase, async: false

  test "a callback nobody waits for is said to be stale", %{conn: conn} do
    conn = get(conn, "/callback/ask_nobody?code=1")
    assert conn.status == 404
    assert conn.resp_body =~ "失效"
  end
end
