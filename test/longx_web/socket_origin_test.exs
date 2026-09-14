defmodule LongxWeb.SocketOriginTest do
  @moduledoc """
  A self-hosted Longx is opened by whatever address the person typed (a LAN
  IP, a hostname, a Tailscale name): the socket's origin check compares the
  Origin against the request's own Host (`check_origin: :conn`), never
  against a configured hostname.
  """
  use LongxWeb.ConnCase, async: true

  defp handshake(conn, host, port, origin) do
    %{conn | host: host, port: port}
    |> put_req_header("origin", origin)
    |> put_req_header("connection", "Upgrade")
    |> put_req_header("upgrade", "websocket")
    |> put_req_header("sec-websocket-version", "13")
    |> put_req_header("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
    |> get("/socket/websocket?vsn=2.0.0")
  end

  test "an origin matching the host the page was served from is accepted", %{conn: conn} do
    conn = handshake(conn, "192.168.2.70", 7788, "http://192.168.2.70:7788")
    assert conn.status != 403
  end

  test "another site's origin is refused", %{conn: conn} do
    conn = handshake(conn, "192.168.2.70", 7788, "http://evil.example")
    assert conn.status == 403
  end
end
