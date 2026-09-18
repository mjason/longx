defmodule Longx.Credentials.HttpTest do
  @moduledoc """
  The one way a credential is used: the service layer makes the request
  with the value injected, only to an allowed host, refreshed first when
  stale, and the answer scrubbed of the secret before anyone reads it.
  """
  use Longx.DataCase, async: false

  alias Longx.Credentials
  alias Longx.Credentials.Credential

  setup do
    Ash.bulk_destroy!(Credential, :destroy, %{}, authorize?: false)
    bypass = Bypass.open()
    %{bypass: bypass, host: "localhost", base: "http://localhost:#{bypass.port}"}
  end

  # the API echoes what it got: method, path, headers, body
  defp echo!(bypass) do
    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      Jason.encode!(%{
        method: conn.method,
        path: conn.request_path,
        query: conn.query_string,
        headers: Map.new(conn.req_headers),
        body: body
      })
      |> then(&Plug.Conn.send_resp(conn, 200, &1))
    end)
  end

  test "an API key goes into the header the row names; the echo comes back scrubbed",
       %{bypass: bypass, host: host, base: base} do
    {:ok, _} =
      Credentials.create_api_key(%{name: "svc", allowed_hosts: [host], secret: "sk-top-secret"})

    echo!(bypass)

    assert {:ok, %{status: 200, body: body, headers: headers}} =
             Credentials.request("svc", :get, base <> "/v1/me")

    assert is_map(headers)
    echoed = Jason.decode!(body)
    assert echoed["method"] == "GET"
    assert echoed["path"] == "/v1/me"
    # the server saw the real value, the caller sees a marker
    refute body =~ "sk-top-secret"
    assert echoed["headers"]["authorization"] == "Bearer [redacted:svc]"
  end

  test "a raw scheme and another header; a placeholder anywhere in the request is substituted and scrubbed",
       %{bypass: bypass, host: host, base: base} do
    {:ok, _} =
      Credentials.create_api_key(%{
        name: "svc",
        allowed_hosts: [host],
        header: "x-api-key",
        scheme: "",
        secret: "raw-key-1"
      })

    echo!(bypass)

    assert {:ok, %{status: 200, body: body}} =
             Credentials.request("svc", "POST", base <> "/q?key={{credential:svc}}",
               headers: %{
                 "x-extra" => "k={{credential:svc}}",
                 "content-type" => "application/json"
               },
               body: ~s({"token":"{{credential:svc}}","n":1})
             )

    echoed = Jason.decode!(body)
    assert echoed["headers"]["x-api-key"] == "[redacted:svc]"
    assert echoed["headers"]["x-extra"] == "k=[redacted:svc]"
    assert echoed["query"] == "key=[redacted:svc]"
    assert echoed["body"] == ~s({"token":"[redacted:svc]","n":1})
    refute body =~ "raw-key-1"
  end

  test "a host outside allowed_hosts is refused before any request; an unknown name too",
       %{bypass: bypass, base: base} do
    {:ok, _} =
      Credentials.create_api_key(%{name: "svc", allowed_hosts: ["api.example"], secret: "s"})

    # Bypass expects nothing: a request would fail the test
    assert {:error, {:host_not_allowed, "localhost"}} = Credentials.request("svc", :get, base)
    assert {:error, :not_found} = Credentials.request("nope", :get, base)
    assert {:error, {:bad_url, _}} = Credentials.request("svc", :get, "not a url")
    Bypass.pass(bypass)
  end

  test "an OAuth2 credential: a stale access token is refreshed first; the new one goes out",
       %{bypass: bypass, host: host, base: base} do
    {:ok, cred} =
      Credentials.create_oauth2(%{
        name: "oa",
        allowed_hosts: [host],
        authorize_url: base <> "/authorize",
        token_url: base <> "/token",
        client_id: "cid",
        client_secret: "csecret",
        extra_params: %{"resource" => "https://mcp.example/mcp"}
      })

    {:ok, _} =
      Credentials.store_tokens(cred, %{
        access_token: "old-token",
        refresh_token: "rt-old",
        expires_at: DateTime.add(DateTime.utc_now(), 30, :second)
      })

    Bypass.expect_once(bypass, "POST", "/token", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      form = URI.decode_query(body)
      assert form["grant_type"] == "refresh_token"
      assert form["refresh_token"] == "rt-old"
      assert form["client_id"] == "cid"
      assert form["client_secret"] == "csecret"
      assert form["resource"] == "https://mcp.example/mcp"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{access_token: "new-token", expires_in: 3600, token_type: "Bearer"})
      )
    end)

    Bypass.expect_once(bypass, "GET", "/api", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer new-token"]
      Plug.Conn.send_resp(conn, 200, "hello new-token")
    end)

    assert {:ok, %{status: 200, body: "hello [redacted:oa]"}} =
             Credentials.request("oa", :get, base <> "/api")

    # the refresh token was kept (the answer had none), the expiry set
    assert {:ok, %{refresh_token: "rt-old", access_token: "new-token", expires_at: at}} =
             Credentials.reveal("oa")

    assert DateTime.diff(at, DateTime.utc_now()) > 3000
    assert [%{status: :ready}] = Credentials.list()
  end

  test "a refresh the server refuses is an error the row remembers; no token, no request",
       %{bypass: bypass, host: host, base: base} do
    {:ok, cred} =
      Credentials.create_oauth2(%{
        name: "oa",
        allowed_hosts: [host],
        authorize_url: base <> "/authorize",
        token_url: base <> "/token",
        client_id: "cid"
      })

    assert {:error, :needs_login} = Credentials.request("oa", :get, base <> "/api")

    {:ok, _} =
      Credentials.store_tokens(cred, %{
        access_token: "old",
        refresh_token: "rt",
        expires_at: DateTime.add(DateTime.utc_now(), -5, :second)
      })

    Bypass.expect_once(bypass, "POST", "/token", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(400, Jason.encode!(%{error: "invalid_grant"}))
    end)

    assert {:error, {:refresh_failed, message}} = Credentials.request("oa", :get, base <> "/api")
    assert message =~ "invalid_grant"
    assert [%{status: :error, last_error: ^message}] = Credentials.list()
  end
end
