defmodule Longx.Credentials.OAuthTest do
  @moduledoc """
  The OAuth2 half: a login the browser completes through Longx's own
  `/callback/credentials` (PKCE, a state), the exchange, the refresh, and
  dynamic client registration for servers that offer it.
  """
  use Longx.DataCase, async: false

  alias Longx.Credentials
  alias Longx.Credentials.{Credential, OAuth}

  setup do
    Ash.bulk_destroy!(Credential, :destroy, %{}, authorize?: false)
    bypass = Bypass.open()
    base = "http://localhost:#{bypass.port}"
    # a login starts with a probe of the authorize endpoint (a rejected client is
    # replaced): the default answer is "fine", a test overrides it
    Bypass.stub(bypass, "GET", "/authorize", &Plug.Conn.send_resp(&1, 302, ""))

    {:ok, cred} =
      Credentials.create_oauth2(%{
        name: "oa",
        allowed_hosts: ["localhost"],
        authorize_url: base <> "/authorize",
        token_url: base <> "/token",
        scopes: "openid offline_access",
        client_id: "cid"
      })

    %{bypass: bypass, base: base, cred: cred}
  end

  defp json!(conn, status, map) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(map))
  end

  test "begin_login builds the authorize URL with PKCE and a state; the callback exchanges the code and stores the tokens",
       %{bypass: bypass, base: base, cred: cred} do
    assert {:ok, %{url: url, state: state, redirect_uri: redirect}} =
             OAuth.begin_login(cred, notify: self())

    assert redirect == OAuth.redirect_uri(nil)
    assert redirect =~ "/callback/credentials"
    %URI{query: query} = URI.parse(url)
    assert String.starts_with?(url, base <> "/authorize?")
    q = URI.decode_query(query)
    assert q["response_type"] == "code"
    assert q["client_id"] == "cid"
    assert q["redirect_uri"] == redirect
    assert q["scope"] == "openid offline_access"
    assert q["state"] == state
    assert q["code_challenge_method"] == "S256"
    assert byte_size(q["code_challenge"]) == 43

    test = self()

    Bypass.expect_once(bypass, "POST", "/token", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:token_request, URI.decode_query(body)})
      json!(conn, 200, %{access_token: "at", refresh_token: "rt", expires_in: 1800})
    end)

    assert {:ok, %Credential{}} = OAuth.complete(state, %{"code" => "the-code"})
    assert_receive {:token_request, form}
    assert form["grant_type"] == "authorization_code"
    assert form["code"] == "the-code"
    assert form["redirect_uri"] == redirect
    assert form["client_id"] == "cid"
    # the verifier hashes to the challenge sent
    assert Base.url_encode64(:crypto.hash(:sha256, form["code_verifier"]), padding: false) ==
             q["code_challenge"]

    assert_receive {:credential_login, ^state, {:ok, %Credential{name: "oa"}}}
    assert {:ok, %{access_token: "at", refresh_token: "rt"}} = Credentials.reveal("oa")
    assert [%{status: :ready}] = Credentials.list()
    # a state is used once
    assert {:error, :unknown_state} = OAuth.complete(state, %{"code" => "again"})
  end

  test "the provider sending an error back, or a token endpoint refusing, ends the login with the reason",
       %{bypass: bypass, cred: cred} do
    {:ok, %{state: state}} = OAuth.begin_login(cred, notify: self())

    assert {:error, message} = OAuth.complete(state, %{"error" => "access_denied"})
    assert message =~ "access_denied"
    assert_receive {:credential_login, ^state, {:error, _}}

    {:ok, %{state: state2}} = OAuth.begin_login(cred, [])

    Bypass.expect_once(bypass, "POST", "/token", fn conn ->
      json!(conn, 400, %{error: "invalid_grant", error_description: "bad code"})
    end)

    assert {:error, message} = OAuth.complete(state2, %{"code" => "x"})
    assert message =~ "invalid_grant"
    assert [%{status: :needs_login}] = Credentials.list()
  end

  test "refresh: the refresh_token grant; a refresh token in the answer replaces the old one; an error is remembered",
       %{bypass: bypass, cred: cred} do
    {:ok, cred} =
      Credentials.store_tokens(cred, %{
        access_token: "at-0",
        refresh_token: "rt-0",
        expires_at: DateTime.add(DateTime.utc_now(), 10, :second)
      })

    Bypass.expect_once(bypass, "POST", "/token", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert URI.decode_query(body)["refresh_token"] == "rt-0"
      json!(conn, 200, %{access_token: "at-1", refresh_token: "rt-1", expires_in: 60})
    end)

    assert {:ok, %Credential{}} = OAuth.refresh(cred)
    assert {:ok, %{access_token: "at-1", refresh_token: "rt-1"}} = Credentials.reveal("oa")

    Bypass.expect_once(bypass, "POST", "/token", fn conn ->
      Plug.Conn.send_resp(conn, 500, "down")
    end)

    assert {:error, message} = OAuth.refresh(cred)
    assert message =~ "500"
    assert [%{status: :error}] = Credentials.list()
    # a credential without a refresh token cannot be refreshed
    {:ok, plain} =
      Credentials.create_oauth2(%{
        name: "plain",
        allowed_hosts: ["localhost"],
        token_url: "http://localhost/token"
      })

    assert {:error, :needs_login} = OAuth.refresh(plain)
  end

  test "dynamic client registration (RFC 7591) runs before the first login when there is no client id",
       %{bypass: bypass, base: base} do
    {:ok, cred} =
      Credentials.create_oauth2(%{
        name: "dyn",
        allowed_hosts: ["localhost"],
        authorize_url: base <> "/authorize",
        token_url: base <> "/token",
        registration_url: base <> "/register"
      })

    Bypass.expect_once(bypass, "POST", "/register", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      req = Jason.decode!(body)
      assert req["redirect_uris"] == [OAuth.redirect_uri(nil)]
      assert req["token_endpoint_auth_method"] == "none"
      assert "authorization_code" in req["grant_types"]
      json!(conn, 201, %{client_id: "generated-id", client_secret: "generated-secret"})
    end)

    assert {:ok, %{url: url}} = OAuth.begin_login(cred, [])
    assert URI.decode_query(URI.parse(url).query)["client_id"] == "generated-id"

    assert {:ok, %{client_id: "generated-id", client_secret: "generated-secret"}} =
             Credentials.reveal("dyn")

    # no registration URL and no client id: nothing to log in with
    {:ok, bare} =
      Credentials.create_oauth2(%{
        name: "bare",
        allowed_hosts: ["localhost"],
        authorize_url: base <> "/authorize",
        token_url: base <> "/token"
      })

    assert {:error, message} = OAuth.begin_login(bare, [])
    assert message =~ "client"
  end

  test "a client the server rejects (another redirect URI) is replaced: the authorize probe answers 400, Longx registers itself at the metadata's registration endpoint and logs in with the new client",
       %{bypass: bypass, base: base, cred: cred} do
    # no registration_url on the row: RFC 8414 metadata names it
    Bypass.expect(bypass, "GET", "/.well-known/oauth-authorization-server", fn conn ->
      json!(conn, 200, %{issuer: base, registration_endpoint: base <> "/register"})
    end)

    Bypass.expect(bypass, "GET", "/authorize", fn conn ->
      case conn.query_params["client_id"] do
        "fresh-id" ->
          conn
          |> Plug.Conn.put_resp_header("location", "https://idp.example/login")
          |> Plug.Conn.send_resp(302, "")

        _ ->
          Plug.Conn.send_resp(conn, 400, "Whitelabel Error Page")
      end
    end)

    Bypass.expect_once(bypass, "POST", "/register", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body)["redirect_uris"] == [OAuth.redirect_uri(nil)]
      json!(conn, 201, %{client_id: "fresh-id"})
    end)

    assert {:ok, %{url: url}} = OAuth.begin_login(cred, [])
    assert URI.decode_query(URI.parse(url).query)["client_id"] == "fresh-id"
    assert {:ok, %{client_id: "fresh-id", registration_url: reg}} = Credentials.fetch("oa")
    assert reg == base <> "/register"
  end

  test "a 400 from the authorize endpoint with no way to register keeps the row and the URL as they are",
       %{bypass: bypass, cred: cred} do
    Bypass.expect(
      bypass,
      "GET",
      "/.well-known/oauth-authorization-server",
      &Plug.Conn.send_resp(&1, 404, "")
    )

    Bypass.stub(
      bypass,
      "GET",
      "/.well-known/openid-configuration",
      &Plug.Conn.send_resp(&1, 404, "")
    )

    Bypass.expect(bypass, "GET", "/authorize", &Plug.Conn.send_resp(&1, 400, "bad client"))
    assert {:ok, %{url: url}} = OAuth.begin_login(cred, [])
    assert URI.decode_query(URI.parse(url).query)["client_id"] == "cid"
  end
end
