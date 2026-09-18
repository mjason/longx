defmodule LongxWeb.CredentialsRpcTest do
  @moduledoc "Credentials on the wire: the settings page's list, create, update, login URL, refresh, delete — never a value."
  use LongxWeb.ConnCase, async: false

  alias Longx.Credentials
  alias Longx.Credentials.Credential

  setup do
    Ash.bulk_destroy!(Credential, :destroy, %{}, authorize?: false)
    :ok
  end

  defp rpc(conn, action, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/rpc/run", Jason.encode!(Map.put(params, "action", action)))
    |> json_response(200)
  end

  @fields ~w(id name label kind header scheme allowedHosts clientId authorizeUrl tokenUrl registrationUrl scopes pkce expiresAt refreshedAt lastError status hasSecret hasAccessToken hasRefreshToken hasClientSecret)

  test "an API key is created with its value, listed without it, updated, deleted", %{conn: conn} do
    assert %{"success" => true, "data" => created} =
             rpc(conn, "create_credential_api_key", %{
               "fields" => @fields,
               "input" => %{
                 "name" => "svc",
                 "label" => "Service",
                 "allowedHosts" => ["api.example"],
                 "secret" => "sk-wire"
               }
             })

    assert created["status"] == "ready"
    assert created["hasSecret"] == true
    refute Map.has_key?(created, "secret")
    refute inspect(created) =~ "sk-wire"

    assert %{"success" => true, "data" => [listed]} =
             rpc(conn, "list_credentials", %{"fields" => @fields})

    assert listed["name"] == "svc"
    assert listed["allowedHosts"] == ["api.example"]
    refute inspect(listed) =~ "sk-wire"

    assert %{"success" => true, "data" => updated} =
             rpc(conn, "update_credential", %{
               "fields" => @fields,
               "identity" => created["id"],
               "input" => %{"allowedHosts" => ["b.example"], "secret" => "sk-2"}
             })

    assert updated["allowedHosts"] == ["b.example"]
    assert {:ok, %{secret: "sk-2"}} = Credentials.reveal("svc")

    # a bad name is an error on its field
    assert %{"success" => false, "errors" => [%{"fields" => ["name"]} | _]} =
             rpc(conn, "create_credential_api_key", %{
               "fields" => @fields,
               "input" => %{"name" => "Bad Name", "allowedHosts" => ["x.y"], "secret" => "s"}
             })

    assert %{"success" => true} =
             rpc(conn, "delete_credential", %{"identity" => created["id"], "fields" => []})

    assert Credentials.list() == []
  end

  test "an OAuth2 credential: the redirect URI to register, the login URL, a refresh", %{
    conn: conn
  } do
    bypass = Bypass.open()
    # a login probes the authorize endpoint first (a rejected client is replaced)
    Bypass.stub(bypass, "GET", "/authorize", &Plug.Conn.send_resp(&1, 302, ""))
    base = "http://localhost:#{bypass.port}"

    assert %{"success" => true, "data" => %{"uri" => uri}} =
             rpc(conn, "credential_redirect_uri", %{"fields" => ["uri"], "input" => %{}})

    assert uri =~ "/callback/credentials"

    assert %{
             "success" => true,
             "data" => %{"uri" => "https://longx.example/callback/credentials"}
           } =
             rpc(conn, "credential_redirect_uri", %{
               "fields" => ["uri"],
               "input" => %{"origin" => "https://longx.example/settings/credentials"}
             })

    assert %{"success" => true, "data" => created} =
             rpc(conn, "create_credential_oauth2", %{
               "fields" => @fields,
               "input" => %{
                 "name" => "oa",
                 "allowedHosts" => ["localhost"],
                 "authorizeUrl" => base <> "/authorize",
                 "tokenUrl" => base <> "/token",
                 "clientId" => "cid",
                 "clientSecret" => "cs-wire",
                 "scopes" => "openid"
               }
             })

    assert created["status"] == "needs_login"
    assert created["hasClientSecret"] == true
    refute inspect(created) =~ "cs-wire"

    assert %{"success" => true, "data" => %{"url" => url, "redirectUri" => redirect}} =
             rpc(conn, "credential_login_url", %{
               "fields" => ["url", "redirectUri"],
               "input" => %{"id" => created["id"], "origin" => "https://longx.example"}
             })

    assert redirect == "https://longx.example/callback/credentials"
    assert String.starts_with?(url, base <> "/authorize?")
    assert URI.decode_query(URI.parse(url).query)["redirect_uri"] == redirect

    # nothing to refresh yet: an error on the id
    assert %{"success" => false, "errors" => [%{"fields" => ["id"]} | _]} =
             rpc(conn, "refresh_credential", %{
               "fields" => @fields,
               "input" => %{"id" => created["id"]}
             })

    {:ok, cred} = Credentials.fetch("oa")

    {:ok, _} =
      Credentials.store_tokens(cred, %{
        access_token: "at",
        refresh_token: "rt",
        expires_at: DateTime.add(DateTime.utc_now(), 30, :second)
      })

    Bypass.expect_once(bypass, "POST", "/token", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{access_token: "at-2", expires_in: 3600}))
    end)

    assert %{"success" => true, "data" => refreshed} =
             rpc(conn, "refresh_credential", %{
               "fields" => @fields,
               "input" => %{"id" => created["id"]}
             })

    assert refreshed["status"] == "ready"
    refute inspect(refreshed) =~ "at-2"
    assert {:ok, %{access_token: "at-2"}} = Credentials.reveal("oa")
  end
end
