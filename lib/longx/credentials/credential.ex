defmodule Longx.Credentials.Credential do
  @moduledoc """
  A named secret Longx keeps for the agent — an API key, or an OAuth2
  client with its tokens — encrypted at rest with `Longx.Vault` (the
  secret, the tokens and the client secret are ciphertext columns,
  decrypted only on purpose: `Ash.load(cred, [:secret])`), and bound to
  `allowed_hosts`: the request layer (`Longx.Credentials.request/4`) sends
  it to those hosts and nowhere else, so an agent holding the *name* of a
  credential can use it but never read it, nor leak it to another host.
  Global (single user); the `name` is the placeholder the agent uses.
  """

  use Ash.Resource,
    otp_app: :longx,
    domain: Longx.Credentials,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshCloak, AshTypescript.Resource]

  alias Longx.Credentials.Credential.{Changes, Validations}

  @slug ~r/^[a-z0-9][a-z0-9_-]{0,63}$/

  sqlite do
    table "credentials"
    repo Longx.Repo
  end

  cloak do
    vault(Longx.Vault)
    attributes([:secret, :access_token, :refresh_token, :client_secret])
    decrypt_by_default([])
    encrypt_nil?(false)
  end

  typescript do
    type_name "Credential"

    field_names has_secret?: "hasSecret",
                has_access_token?: "hasAccessToken",
                has_refresh_token?: "hasRefreshToken",
                has_client_secret?: "hasClientSecret"
  end

  actions do
    defaults [:read, :destroy]

    create :create_api_key do
      accept [:name, :label, :header, :scheme, :allowed_hosts, :secret]
      change set_attribute(:kind, :api_key)
      change Changes.NormaliseHosts
    end

    create :create_oauth2 do
      accept [
        :name,
        :label,
        :header,
        :scheme,
        :allowed_hosts,
        :client_id,
        :client_secret,
        :authorize_url,
        :token_url,
        :registration_url,
        :scopes,
        :pkce,
        :extra_params
      ]

      change set_attribute(:kind, :oauth2)
      change Changes.NormaliseHosts
    end

    update :update do
      primary? true
      require_atomic? false

      accept [
        :label,
        :header,
        :scheme,
        :allowed_hosts,
        :secret,
        :client_id,
        :client_secret,
        :authorize_url,
        :token_url,
        :registration_url,
        :scopes,
        :pkce,
        :extra_params
      ]

      change Changes.NormaliseHosts
    end

    # what a login or a refresh brought back; an error is over once tokens land
    update :store_tokens do
      require_atomic? false
      accept [:access_token, :refresh_token, :expires_at]
      change set_attribute(:refreshed_at, &DateTime.utc_now/0)
      change set_attribute(:last_error, nil)
      change set_attribute(:last_error_at, nil)
    end

    # a dynamic registration's outcome (RFC 7591)
    update :store_client do
      require_atomic? false
      accept [:client_id, :client_secret]
    end

    update :record_error do
      require_atomic? false
      argument :message, :string, allow_nil?: false
      change set_attribute(:last_error, arg(:message))
      change set_attribute(:last_error_at, &DateTime.utc_now/0)
    end

    read :by_name do
      argument :name, :string, allow_nil?: false
      get? true
      filter expr(name == ^arg(:name))
    end

    # the settings page's 登录: where to send the browser; it comes back
    # through /callback/credentials and the tokens land on the row
    action :login_url, :map do
      constraints fields: [
                    url: [type: :string, allow_nil?: false],
                    redirect_uri: [type: :string, allow_nil?: false],
                    # a loopback redirect: a browser on another machine lands on an
                    # unreachable page and the person pastes its address (complete_url)
                    loopback: [type: :boolean, allow_nil?: false]
                  ]

      argument :id, :uuid, allow_nil?: false
      # the address the person's browser reached Longx by, else the public URL
      argument :origin, :string

      run fn input, _ ->
        with {:ok, cred} <- Ash.get(__MODULE__, input.arguments.id),
             {:ok, %{url: url, redirect_uri: redirect}} <-
               Longx.Credentials.OAuth.begin_login(cred,
                 origin: Map.get(input.arguments, :origin)
               ) do
          {:ok,
           %{
             url: url,
             redirect_uri: redirect,
             loopback: Longx.Credentials.OAuth.loopback?(redirect)
           }}
        else
          {:error, message} when is_binary(message) ->
            {:error,
             Ash.Error.Invalid.exception(
               errors: [Ash.Error.Changes.InvalidArgument.exception(field: :id, message: message)]
             )}

          other ->
            other
        end
      end
    end

    # the address the browser was sent to after the login, pasted by the person
    action :complete_url, :struct do
      constraints instance_of: __MODULE__
      argument :url, :string, allow_nil?: false

      run fn input, _ ->
        case Longx.Credentials.OAuth.complete_url(input.arguments.url) do
          {:ok, cred} ->
            Ash.get(__MODULE__, cred.id, load: Longx.Credentials.list_load())

          {:error, message} ->
            {:error,
             Ash.Error.Invalid.exception(
               errors: [
                 Ash.Error.Changes.InvalidArgument.exception(field: :url, message: message)
               ]
             )}
        end
      end
    end

    action :refresh, :struct do
      constraints instance_of: __MODULE__
      argument :id, :uuid, allow_nil?: false

      run fn input, _ ->
        with {:ok, cred} <- Ash.get(__MODULE__, input.arguments.id),
             {:ok, _} <- Longx.Credentials.OAuth.refresh(cred),
             {:ok, fresh} <- Longx.Credentials.fetch(cred.name) do
          {:ok, fresh}
        else
          {:error, :needs_login} ->
            {:error,
             Ash.Error.Invalid.exception(
               errors: [
                 Ash.Error.Changes.InvalidArgument.exception(
                   field: :id,
                   message: "nothing to refresh: log in first"
                 )
               ]
             )}

          {:error, message} when is_binary(message) ->
            {:error,
             Ash.Error.Invalid.exception(
               errors: [Ash.Error.Changes.InvalidArgument.exception(field: :id, message: message)]
             )}

          other ->
            other
        end
      end
    end

    # what to register at the provider as the redirect URI
    action :redirect_uri, :map do
      constraints fields: [uri: [type: :string, allow_nil?: false]]
      argument :origin, :string

      run fn input, _ ->
        {:ok, %{uri: Longx.Credentials.OAuth.redirect_uri(Map.get(input.arguments, :origin))}}
      end
    end
  end

  validations do
    validate match(:name, @slug),
      message: "must be a short lowercase slug (a-z, 0-9, - and _)",
      where: [changing(:name)]

    validate Validations.Hosts

    validate match(:authorize_url, ~r{^https?://}),
      message: "must start with http:// or https://",
      where: [changing(:authorize_url), present(:authorize_url)]

    validate match(:token_url, ~r{^https?://}),
      message: "must start with http:// or https://",
      where: [changing(:token_url), present(:token_url)]
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string, allow_nil?: false, public?: true
    attribute :label, :string, public?: true

    attribute :kind, :atom do
      allow_nil? false
      public? true
      default :api_key
      constraints one_of: [:api_key, :oauth2]
    end

    # where the value goes on a request: the header, and the scheme in front
    # of it ("Bearer" → `Authorization: Bearer …`; "" → the raw value)
    attribute :header, :string, allow_nil?: false, default: "authorization", public?: true

    attribute :scheme, :string do
      allow_nil? false
      default "Bearer"
      public? true
      # "" is a real choice: the raw value, no scheme in front
      constraints allow_empty?: true
    end

    # the hosts this credential may be sent to — the boundary against exfiltration
    attribute :allowed_hosts, {:array, :string}, allow_nil?: false, default: [], public?: true

    # ciphertext columns (AshCloak): never public, loaded on purpose
    attribute :secret, :string, sensitive?: true
    attribute :access_token, :string, sensitive?: true
    attribute :refresh_token, :string, sensitive?: true
    attribute :client_secret, :string, sensitive?: true

    # OAuth2 client
    attribute :client_id, :string, public?: true
    attribute :authorize_url, :string, public?: true
    attribute :token_url, :string, public?: true
    # RFC 7591 dynamic client registration, for servers that offer it
    attribute :registration_url, :string, public?: true
    attribute :scopes, :string, public?: true
    attribute :pkce, :boolean, allow_nil?: false, default: true, public?: true
    # extra form fields on token requests (e.g. `resource`)
    attribute :extra_params, :map, allow_nil?: false, default: %{}, public?: true

    attribute :expires_at, :utc_datetime_usec, public?: true
    attribute :refreshed_at, :utc_datetime_usec, public?: true
    attribute :last_error, :string, public?: true
    attribute :last_error_at, :utc_datetime_usec, public?: true

    timestamps public?: true
  end

  calculations do
    calculate :has_secret?, :boolean, expr(not is_nil(encrypted_secret)), public?: true

    calculate :has_access_token?, :boolean, expr(not is_nil(encrypted_access_token)),
      public?: true

    calculate :has_refresh_token?, :boolean, expr(not is_nil(encrypted_refresh_token)),
      public?: true

    calculate :has_client_secret?, :boolean, expr(not is_nil(encrypted_client_secret)),
      public?: true

    # ready | expired | needs_login | error — what the list and the agent see
    calculate :status, :atom, Longx.Credentials.Credential.Status do
      public? true
      constraints one_of: [:ready, :expired, :needs_login, :error]
    end
  end

  identities do
    identity :unique_name, [:name]
  end
end
