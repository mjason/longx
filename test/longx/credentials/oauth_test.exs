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
    # a public client without a registration URL was not registered by Longx: the
    # server's metadata is asked for a registration endpoint; none here by default
    for path <- ["/.well-known/oauth-authorization-server", "/.well-known/openid-configuration"],
        do: Bypass.stub(bypass, "GET", path, &Plug.Conn.send_resp(&1, 404, ""))

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

  test "a provider's own client (OpenAI's Codex app): a fixed redirect URI, authorize-only params, the client never replaced",
       %{bypass: bypass, base: base} do
    # the metadata offers registration — a foreign public client would be replaced by it
    Bypass.stub(bypass, "GET", "/.well-known/openid-configuration", fn conn ->
      json!(conn, 200, %{registration_endpoint: base <> "/register"})
    end)

    Bypass.stub(bypass, "POST", "/register", fn conn ->
      json!(conn, 201, %{client_id: "replaced"})
    end)

    {:ok, cred} =
      Credentials.create_oauth2(%{
        name: "chatgpt",
        allowed_hosts: ["localhost"],
        authorize_url: base <> "/authorize",
        token_url: base <> "/token",
        scopes: "openid profile email offline_access",
        client_id: "app_fixed",
        fixed_client: true,
        redirect_uri: "http://localhost:1455/auth/callback",
        authorize_params: %{"codex_cli_simplified_flow" => "true", "originator" => "codex_cli_rs"}
      })

    assert {:ok, %{url: url, redirect_uri: "http://localhost:1455/auth/callback"}} =
             OAuth.begin_login(cred, [])

    q = URI.decode_query(URI.parse(url).query)
    assert q["client_id"] == "app_fixed"
    assert q["redirect_uri"] == "http://localhost:1455/auth/callback"
    assert q["codex_cli_simplified_flow"] == "true"
    assert q["originator"] == "codex_cli_rs"
    # the row keeps its client: no registration happened
    assert {:ok, %Credential{client_id: "app_fixed"}} = Credentials.fetch("chatgpt")

    # the token request carries none of the authorize-only params
    test = self()

    Bypass.expect_once(bypass, "POST", "/token", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:token_request, URI.decode_query(body)})
      json!(conn, 200, %{access_token: "at", refresh_token: "rt", expires_in: 1800})
    end)

    assert {:ok, _} =
             OAuth.complete_url("http://localhost:1455/auth/callback?code=c1&state=#{q["state"]}")

    assert_receive {:token_request, form}
    assert form["redirect_uri"] == "http://localhost:1455/auth/callback"
    refute Map.has_key?(form, "codex_cli_simplified_flow")
  end

  test "the device-code flow (OpenAI's): a user code to type at the verification page, a poll, then the exchange with the verifier the server hands back",
       %{bypass: bypass, base: base} do
    test = self()

    Bypass.expect_once(bypass, "POST", "/api/accounts/deviceauth/usercode", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:usercode_request, Jason.decode!(body)})
      json!(conn, 200, %{device_auth_id: "dev-1", user_code: "ABCD-EFGH", interval: 1})
    end)

    {:ok, cred} =
      Credentials.create_oauth2(%{
        name: "chatgpt",
        allowed_hosts: ["localhost"],
        authorize_url: base <> "/oauth/authorize",
        token_url: base <> "/oauth/token",
        scopes: "openid offline_access",
        client_id: "app_fixed",
        fixed_client: true,
        device_flow: :openai
      })

    assert {:ok, %{state: state, user_code: "ABCD-EFGH", verification_url: url, interval: 1}} =
             OAuth.device_begin(cred)

    assert url == base <> "/codex/device"
    assert_receive {:usercode_request, %{"client_id" => "app_fixed"}}

    # not approved yet: the poll says so
    Bypass.expect_once(
      bypass,
      "POST",
      "/api/accounts/deviceauth/token",
      &Plug.Conn.send_resp(&1, 403, "")
    )

    assert {:ok, :pending} = OAuth.device_poll(state)

    # approved: the server hands the code and the verifier it made; the exchange uses its own callback
    Bypass.expect_once(bypass, "POST", "/api/accounts/deviceauth/token", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:poll_request, Jason.decode!(body)})

      json!(conn, 200, %{
        authorization_code: "ac-1",
        code_verifier: "ver-1",
        code_challenge: "ch-1"
      })
    end)

    Bypass.expect_once(bypass, "POST", "/oauth/token", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:token_request, URI.decode_query(body)})
      json!(conn, 200, %{access_token: "at", refresh_token: "rt", expires_in: 1800})
    end)

    assert {:ok, %Credential{name: "chatgpt"}} = OAuth.device_poll(state)
    assert_receive {:poll_request, %{"device_auth_id" => "dev-1", "user_code" => "ABCD-EFGH"}}
    assert_receive {:token_request, form}
    assert form["grant_type"] == "authorization_code"
    assert form["code"] == "ac-1"
    assert form["code_verifier"] == "ver-1"
    assert form["redirect_uri"] == base <> "/deviceauth/callback"
    assert %{status: :ready} = Enum.find(Credentials.list(), &(&1.name == "chatgpt"))
    # the state is spent
    assert {:error, :unknown_state} = OAuth.device_poll(state)
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

  test "a client the server rejects (another redirect URI) is replaced: the authorize probe answers 400, Longx registers itself again at the row's registration URL",
       %{bypass: bypass, base: base} do
    # registered by Longx once (registration_url on the row), rejected since
    {:ok, cred} =
      Credentials.create_oauth2(%{
        name: "reg",
        allowed_hosts: ["localhost"],
        authorize_url: base <> "/authorize",
        token_url: base <> "/token",
        client_id: "old-id",
        registration_url: base <> "/register"
      })

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
    assert {:ok, %{client_id: "fresh-id"}} = Credentials.fetch("reg")
  end

  test "a 400 from the authorize endpoint with no way to register keeps the row and the URL as they are",
       %{bypass: bypass, cred: cred} do
    Bypass.stub(bypass, "GET", "/authorize", &Plug.Conn.send_resp(&1, 400, "bad client"))
    assert {:ok, %{url: url}} = OAuth.begin_login(cred, [])
    assert URI.decode_query(URI.parse(url).query)["client_id"] == "cid"
  end

  test "a public client Longx did not register (a client id by hand, no secret, no registration URL) is replaced before the first login when the server registers clients",
       %{bypass: bypass, base: base, cred: cred} do
    Bypass.expect(bypass, "GET", "/.well-known/oauth-authorization-server", fn conn ->
      json!(conn, 200, %{issuer: base, registration_endpoint: base <> "/register"})
    end)

    Bypass.expect_once(bypass, "POST", "/register", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body)["redirect_uris"] == [OAuth.redirect_uri(nil)]
      json!(conn, 201, %{client_id: "longx-id"})
    end)

    # the authorize endpoint answers 302 to the IdP for any client: no 400 to probe
    assert {:ok, %{url: url}} = OAuth.begin_login(cred, [])
    assert URI.decode_query(URI.parse(url).query)["client_id"] == "longx-id"
    assert {:ok, %{client_id: "longx-id", registration_url: reg}} = Credentials.fetch("oa")
    assert reg == base <> "/register"

    # registered by Longx now: the next login keeps it (Bypass expected one registration)
    {:ok, registered} = Credentials.fetch("oa")
    assert {:ok, %{url: url2}} = OAuth.begin_login(registered, [])
    assert URI.decode_query(URI.parse(url2).query)["client_id"] == "longx-id"
  end

  test "a confidential client (a secret from the provider's console) is used as it is: no discovery, no registration",
       %{bypass: _bypass, base: base} do
    {:ok, cred} =
      Credentials.create_oauth2(%{
        name: "conf",
        allowed_hosts: ["localhost"],
        authorize_url: base <> "/authorize",
        token_url: base <> "/token",
        client_id: "console-id",
        client_secret: "console-secret"
      })

    # no metadata stub: a fetch would fail the test as an unexpected request
    assert {:ok, %{url: url}} = OAuth.begin_login(cred, [])
    assert URI.decode_query(URI.parse(url).query)["client_id"] == "console-id"
  end

  describe "the redirect URI — a provider takes https or loopback (RFC 8252), never a remote http address" do
    test "an https origin is used as it is; anything else becomes Longx's own loopback address on its port" do
      assert OAuth.redirect_uri("https://longx.example") ==
               "https://longx.example/callback/credentials"

      assert OAuth.redirect_uri("https://longx.example:8443/") ==
               "https://longx.example:8443/callback/credentials"

      # the test endpoint listens on 4002
      assert OAuth.redirect_uri("http://192.168.2.129:7798") ==
               "http://127.0.0.1:4002/callback/credentials"

      assert OAuth.redirect_uri(nil) == "http://127.0.0.1:4002/callback/credentials"
      assert OAuth.loopback?("http://127.0.0.1:4002/callback/credentials")
      refute OAuth.loopback?("https://longx.example/callback/credentials")
    end

    test "the redirected URL pasted by the person completes the login (the browser was on another machine)",
         %{bypass: bypass, cred: cred} do
      {:ok, %{state: state, redirect_uri: redirect}} = OAuth.begin_login(cred, notify: self())
      assert OAuth.loopback?(redirect)

      Bypass.expect_once(bypass, "POST", "/token", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert URI.decode_query(body)["code"] == "pasted-code"
        json!(conn, 200, %{access_token: "at", refresh_token: "rt", expires_in: 1800})
      end)

      pasted = redirect <> "?code=pasted-code&state=" <> state
      assert {:ok, %Credential{name: "oa"}} = OAuth.complete_url(pasted)
      assert_receive {:credential_login, ^state, {:ok, _}}
      # not a URL of ours, or without a state: said so
      assert {:error, message} = OAuth.complete_url("https://example.com/?code=x")
      assert message =~ "state"
      assert {:error, message} = OAuth.complete_url("not a url at all")
      assert message =~ "state"
    end

    test "a registration the provider refuses is the login's error, with the provider's words",
         %{bypass: bypass, base: base} do
      {:ok, cred} =
        Credentials.create_oauth2(%{
          name: "ref",
          allowed_hosts: ["localhost"],
          authorize_url: base <> "/authorize",
          token_url: base <> "/token",
          registration_url: base <> "/register"
        })

      Bypass.expect_once(bypass, "POST", "/register", fn conn ->
        json!(conn, 400, %{
          error: "invalid_redirect_uri",
          error_description: "Remote redirect_uri must use https"
        })
      end)

      assert {:error, message} = OAuth.begin_login(cred, [])
      assert message =~ "Remote redirect_uri must use https"

      # the same for a foreign public client the provider will not re-register
      Bypass.expect(bypass, "GET", "/.well-known/oauth-authorization-server", fn conn ->
        json!(conn, 200, %{issuer: base, registration_endpoint: base <> "/register"})
      end)

      Bypass.expect_once(bypass, "POST", "/register", fn conn ->
        json!(conn, 400, %{error: "invalid_redirect_uri"})
      end)

      {:ok, foreign} = Credentials.fetch("oa")
      assert {:error, message} = OAuth.begin_login(foreign, [])
      assert message =~ "invalid_redirect_uri"
    end
  end
end
