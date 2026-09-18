defmodule Longx.Credentials do
  @moduledoc """
  Credentials — the API keys and OAuth2 tokens Longx keeps for the agent,
  and the one way they are used.

  The agent never holds a secret: it names a credential and the service
  layer does the request (`request/4`) — the value injected into the
  header the row names (or a `{{credential:NAME}}` placeholder anywhere
  in the URL, the headers or the body), only to a host in the row's
  `allowed_hosts`, the access token refreshed first when it is about to
  expire, and the answer scrubbed of every secret value before it goes
  back. OAuth2 tokens are refreshed in the background by
  `Longx.Credentials.RefreshWorker` (Oban, every five minutes) and by hand
  from the settings page; a login is `Longx.Credentials.OAuth` (PKCE,
  the browser sent back to `<public url>/callback/credentials`).
  """

  use Ash.Domain, otp_app: :longx, extensions: [AshTypescript.Rpc]

  require Ash.Query

  alias Longx.Credentials.{Credential, Http, OAuth}

  typescript_rpc do
    resource Credential do
      rpc_action :list_credentials, :read
      rpc_action :create_credential_api_key, :create_api_key
      rpc_action :create_credential_oauth2, :create_oauth2
      rpc_action :update_credential, :update
      rpc_action :delete_credential, :destroy
      rpc_action :credential_login_url, :login_url
      rpc_action :refresh_credential, :refresh
      rpc_action :credential_complete_url, :complete_url
      rpc_action :credential_redirect_uri, :redirect_uri
    end
  end

  resources do
    resource Credential do
      define :create_api_key, action: :create_api_key
      define :create_oauth2, action: :create_oauth2
      define :update_credential, action: :update
      define :store_tokens, action: :store_tokens
      define :store_client, action: :store_client
      define :record_error, action: :record_error, args: [:message]
      define :get_by_name, action: :by_name, args: [:name]
    end
  end

  @list_load [
    :status,
    :has_secret?,
    :has_access_token?,
    :has_refresh_token?,
    :has_client_secret?
  ]

  @doc "Every credential with its status — never a secret value."
  @spec list() :: [Credential.t()]
  def list do
    Credential
    |> Ash.Query.sort(:name)
    |> Ash.Query.load(@list_load)
    |> Ash.read!()
  end

  @doc false
  def list_load, do: @list_load

  @doc "The row by name, with its status (no secrets)."
  @spec fetch(String.t()) :: {:ok, Credential.t()} | {:error, :not_found}
  def fetch(name) when is_binary(name) do
    case get_by_name(name, load: @list_load) do
      {:ok, %Credential{} = cred} -> {:ok, cred}
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc """
  The row with its secret values decrypted — for the request layer and
  the OAuth flow, never for the wire or the model.
  """
  @spec reveal(String.t() | Credential.t()) :: {:ok, Credential.t()} | {:error, :not_found}
  def reveal(%Credential{} = cred),
    do: {:ok, Ash.load!(cred, [:secret, :access_token, :refresh_token, :client_secret])}

  def reveal(name) when is_binary(name) do
    with {:ok, cred} <- fetch(name), do: reveal(cred)
  end

  @spec delete(Credential.t()) :: :ok | {:error, term}
  def delete(%Credential{} = cred), do: Ash.destroy(cred)

  @doc "A request with the credential injected — see `Longx.Credentials.Http.request/4`."
  @spec request(String.t(), String.t() | atom, String.t(), keyword) ::
          {:ok, Http.response()} | {:error, term}
  defdelegate request(name, method, url, opts \\ []), to: Http

  @doc "Refreshes an OAuth2 credential's tokens now — see `Longx.Credentials.OAuth.refresh/1`."
  @spec refresh(Credential.t() | String.t()) :: {:ok, Credential.t()} | {:error, term}
  def refresh(%Credential{} = cred), do: OAuth.refresh(cred)

  def refresh(name) when is_binary(name) do
    with {:ok, cred} <- fetch(name), do: OAuth.refresh(cred)
  end

  @doc "The credentials whose access token expires within `within_seconds` (the worker's list)."
  @spec expiring(pos_integer) :: [Credential.t()]
  def expiring(within_seconds) do
    cutoff = DateTime.add(DateTime.utc_now(), within_seconds, :second)

    Credential
    |> Ash.Query.filter(kind == :oauth2 and not is_nil(expires_at) and expires_at <= ^cutoff)
    |> Ash.Query.load(@list_load)
    |> Ash.read!()
    |> Enum.filter(& &1.has_refresh_token?)
  end
end
