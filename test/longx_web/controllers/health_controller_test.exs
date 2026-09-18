defmodule LongxWeb.HealthControllerTest do
  use LongxWeb.ConnCase, async: true

  # a container's healthcheck and a proxy's probe: 200 "ok" with the version, nothing else
  test "GET /health answers ok with the version", %{conn: conn} do
    conn = get(conn, "/health")
    assert response(conn, 200) =~ "ok"
    assert response_content_type(conn, :text) =~ "text/plain"
    assert get_resp_header(conn, "x-longx-version") == [Longx.Upgrade.current_version()]
  end
end
