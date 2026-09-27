defmodule LongxWeb.Plugs.HttpsRedirectTest do
  @moduledoc """
  While Longx serves HTTPS itself and the settings say so, a page asked for
  over plain http is sent to the https address; nothing else is — the
  health check, the API, webhooks, callbacks, downloads, sockets and the
  GraphQL calls keep working on http.
  """
  use LongxWeb.ConnCase, async: false

  setup do
    on_exit(fn -> Longx.Tls.publish(nil, false) end)
    :ok
  end

  defp page(conn, path),
    do: conn |> put_req_header("accept", "text/html,application/xhtml+xml") |> get(path)

  test "a page is sent to the https address, its path and query kept", %{conn: conn} do
    :ok = Longx.Tls.publish("https://lx.example.com:7443", true)
    conn = page(conn, "/p/demo/t/1?tab=files")
    assert conn.status == 307

    assert get_resp_header(conn, "location") == [
             "https://lx.example.com:7443/p/demo/t/1?tab=files"
           ]
  end

  test "nothing moves while HTTPS is off or the redirect is switched off", %{conn: conn} do
    assert page(conn, "/").status == 200
    :ok = Longx.Tls.publish("https://lx.example.com:7443", false)
    assert page(build_conn(), "/").status == 200
  end

  test "what is not a page stays on http", %{conn: _conn} do
    :ok = Longx.Tls.publish("https://lx.example.com:7443", true)
    assert build_conn() |> get("/health") |> Map.fetch!(:status) == 200
    # a JSON client
    assert build_conn()
           |> put_req_header("accept", "application/json")
           |> get("/")
           |> Map.fetch!(:status) != 307

    for path <-
          ~w(/api/p/demo /hooks/abc /callback/credentials /files/x/y /extension/longx-chrome.zip /gql /attachments/x) do
      assert page(build_conn(), path).status != 307, "#{path} should stay on http"
    end

    # not a GET
    assert build_conn()
           |> put_req_header("accept", "text/html")
           |> post("/")
           |> Map.fetch!(:status) != 307
  end

  test "the HTTPS settings page itself never moves: the way back when the name does not resolve",
       %{
         conn: conn
       } do
    :ok = Longx.Tls.publish("https://lx.example.com:7443", true)
    assert page(conn, "/settings/https").status == 200
    assert page(build_conn(), "/settings/models").status == 307
  end

  test "a request already on https is left alone", %{conn: conn} do
    :ok = Longx.Tls.publish("https://lx.example.com:7443", true)
    # a full URL: a bare path makes the test adapter build the request as http
    assert page(conn, "https://lx.example.com:7443/").status == 200
  end
end
