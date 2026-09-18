defmodule LongxWeb.CallbackControllerTest do
  use LongxWeb.ConnCase, async: false

  alias Longx.Credentials
  alias Longx.Credentials.{Credential, OAuth}

  test "a callback nobody waits for is said to be stale", %{conn: conn} do
    conn = get(conn, "/callback/ask_nobody?code=1")
    assert conn.status == 404
    assert conn.resp_body =~ "失效"
  end

  describe "/callback/credentials" do
    setup do
      Ash.bulk_destroy!(Credential, :destroy, %{}, authorize?: false)
      bypass = Bypass.open()
      # a login probes the authorize endpoint first (a rejected client is replaced)
      Bypass.stub(bypass, "GET", "/authorize", &Plug.Conn.send_resp(&1, 302, ""))

      for path <- ["/.well-known/oauth-authorization-server", "/.well-known/openid-configuration"],
          do: Bypass.stub(bypass, "GET", path, &Plug.Conn.send_resp(&1, 404, ""))

      base = "http://localhost:#{bypass.port}"

      {:ok, cred} =
        Credentials.create_oauth2(%{
          name: "oa",
          allowed_hosts: ["localhost"],
          authorize_url: base <> "/authorize",
          token_url: base <> "/token",
          client_id: "cid"
        })

      %{bypass: bypass, cred: cred}
    end

    test "the browser's return completes the login and the tokens land on the row",
         %{conn: conn, bypass: bypass, cred: cred} do
      {:ok, %{state: state}} = OAuth.begin_login(cred, [])

      Bypass.expect_once(bypass, "POST", "/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{access_token: "at", expires_in: 60}))
      end)

      conn = get(conn, "/callback/credentials?code=abc&state=#{state}")
      assert conn.status == 200
      assert conn.resp_body =~ "登录成功"
      assert {:ok, %{access_token: "at"}} = Credentials.reveal("oa")
    end

    test "an unknown state is stale; a provider error and a missing state are said",
         %{conn: conn, cred: cred} do
      conn1 = get(conn, "/callback/credentials?code=abc&state=nope")
      assert conn1.status == 404

      {:ok, %{state: state}} = OAuth.begin_login(cred, [])
      conn2 = get(conn, "/callback/credentials?error=access_denied&state=#{state}")
      assert conn2.status == 400
      assert conn2.resp_body =~ "access_denied"

      conn3 = get(conn, "/callback/credentials?code=abc")
      assert conn3.status == 400
    end
  end
end
