defmodule Longx.Credentials.CredentialTest do
  @moduledoc """
  A credential is a named secret Longx keeps for the agent: encrypted at
  rest, listed without its value, bound to the hosts it may be sent to.
  """
  use Longx.DataCase, async: false

  alias Longx.Credentials
  alias Longx.Credentials.Credential

  setup do
    Ash.bulk_destroy!(Credential, :destroy, %{}, authorize?: false)
    :ok
  end

  test "an API key: the value is ciphertext in the row, absent from the listing, readable only on purpose" do
    assert {:ok, %Credential{} = cred} =
             Credentials.create_api_key(%{
               name: "coros",
               label: "COROS MCP",
               allowed_hosts: ["mcpcn.coros.com"],
               secret: "sk-test-value"
             })

    assert cred.kind == :api_key
    assert cred.header == "authorization"
    assert cred.scheme == "Bearer"
    assert is_binary(cred.encrypted_secret)
    refute cred.encrypted_secret =~ "sk-test-value"

    [listed] = Credentials.list()
    assert listed.name == "coros"
    assert listed.status == :ready
    assert listed.has_secret?
    refute is_binary(Map.get(listed, :secret))
    refute inspect(listed) =~ "sk-test-value"

    assert {:ok, %{secret: "sk-test-value"}} = Credentials.reveal("coros")
  end

  test "a name is a slug and unique; the hosts are required and normalised" do
    assert {:error, %Ash.Error.Invalid{}} =
             Credentials.create_api_key(%{name: "Bad Name", allowed_hosts: ["a.b"], secret: "x"})

    assert {:error, %Ash.Error.Invalid{}} =
             Credentials.create_api_key(%{name: "ok", allowed_hosts: [], secret: "x"})

    assert {:ok, cred} =
             Credentials.create_api_key(%{
               name: "ok",
               allowed_hosts: ["  API.Example.com ", "https://other.example/v1"],
               secret: "x"
             })

    assert cred.allowed_hosts == ["api.example.com", "other.example"]

    assert {:error, %Ash.Error.Invalid{}} =
             Credentials.create_api_key(%{name: "ok", allowed_hosts: ["a.b"], secret: "y"})
  end

  test "an OAuth2 credential without tokens needs a login; expiry and errors show in the status" do
    assert {:ok, cred} =
             Credentials.create_oauth2(%{
               name: "coros",
               allowed_hosts: ["mcpcn.coros.com"],
               authorize_url: "https://mcpcn.coros.com/oauth2/authorize",
               token_url: "https://mcpcn.coros.com/oauth2/token",
               scopes: "openid mcp.tools offline_access",
               client_id: "abc"
             })

    assert cred.kind == :oauth2
    assert cred.pkce
    assert [%{status: :needs_login}] = Credentials.list()

    {:ok, cred} =
      Credentials.store_tokens(cred, %{
        access_token: "at-1",
        refresh_token: "rt-1",
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })

    assert [%{status: :ready, has_refresh_token?: true}] = Credentials.list()
    refute cred.encrypted_access_token =~ "at-1"

    {:ok, _} =
      Credentials.store_tokens(cred, %{
        access_token: "at-1",
        expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
      })

    assert [%{status: :expired}] = Credentials.list()

    {:ok, _} = Credentials.record_error(cred, "refresh refused: invalid_grant")
    assert [%{status: :error, last_error: "refresh refused: invalid_grant"}] = Credentials.list()
  end

  test "delete removes it; update changes the hosts and the secret without touching the tokens" do
    {:ok, cred} =
      Credentials.create_api_key(%{name: "k", allowed_hosts: ["a.example"], secret: "one"})

    {:ok, cred} =
      Credentials.update_credential(cred, %{allowed_hosts: ["b.example"], secret: "two"})

    assert cred.allowed_hosts == ["b.example"]
    assert {:ok, %{secret: "two"}} = Credentials.reveal("k")
    {:ok, cred} = Credentials.update_credential(cred, %{label: "Key"})
    assert {:ok, %{secret: "two"}} = Credentials.reveal("k")
    assert cred.label == "Key"
    assert :ok = Credentials.delete(cred)
    assert Credentials.list() == []
    assert {:error, :not_found} = Credentials.reveal("k")
  end
end
