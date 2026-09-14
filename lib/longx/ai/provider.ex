defmodule Longx.AI.Provider do
  @moduledoc """
  An upstream model provider that speaks the OpenAI Responses API
  (OpenAI, DeepSeek, GLM, …). Holds the base URL and the API key; the key is
  encrypted at rest with `Longx.Vault` and only decrypted when explicitly
  loaded (`Ash.load(provider, :api_key)`).
  """

  use Ash.Resource,
    otp_app: :longx,
    domain: Longx.AI,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshCloak, AshTypescript.Resource]

  sqlite do
    table "ai_providers"
    repo Longx.Repo
  end

  cloak do
    vault(Longx.Vault)
    attributes([:api_key])
    decrypt_by_default([])
    encrypt_nil?(false)
  end

  typescript do
    type_name "Provider"
    # the key itself never leaves the server; the UI only learns whether one is set
    field_names has_api_key?: "hasApiKey"
  end

  actions do
    defaults [:read, :destroy]

    # the settings page's delete: its models go with it — unless one of them
    # is the default, then pick another first
    destroy :delete do
      require_atomic? false
      validate Longx.AI.Provider.Validations.NoDefaultModel
      change cascade_destroy(:models, return_notifications?: false, after_action?: false)
    end

    create :create do
      primary? true

      accept [
        :name,
        :slug,
        :kind,
        :base_url,
        :api_key,
        :supports_hosted_web_search,
        :request_timeout_ms,
        :max_concurrent_requests
      ]

      change Longx.AI.Provider.Changes.DeriveKind
    end

    update :update do
      primary? true

      accept [
        :name,
        :kind,
        :base_url,
        :api_key,
        :supports_hosted_web_search,
        :request_timeout_ms,
        :max_concurrent_requests
      ]
    end

    # What the wire last told us about this provider (auth failures, health checks).
    update :record_error do
      argument :message, :string, allow_nil?: false
      change set_attribute(:last_error, arg(:message))
      change set_attribute(:last_error_at, &DateTime.utc_now/0)
    end

    update :clear_error do
      change set_attribute(:last_error, nil)
      change set_attribute(:last_error_at, nil)
    end

    update :record_check do
      require_atomic? false
      argument :error, :string
      change set_attribute(:last_checked_at, &DateTime.utc_now/0)
      change set_attribute(:last_error, arg(:error))
      change Longx.AI.Provider.Changes.ErrorAtFromError
    end

    read :by_slug do
      argument :slug, :string, allow_nil?: false
      get? true
      filter expr(slug == ^arg(:slug))
    end
  end

  validations do
    validate match(:base_url, ~r{^https?://}),
      message: "must start with http:// or https://",
      where: [changing(:base_url)]
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string, allow_nil?: false, public?: true
    attribute :slug, :string, allow_nil?: false, public?: true

    # Root of the OpenAI-compatible API, e.g. https://api.deepseek.com/v1
    attribute :base_url, :string, allow_nil?: false, public?: true

    attribute :api_key, :string, sensitive?: true

    # :openai is the one provider whose reasoning items carry real ciphertext
    # that only it can read; every other Responses API host is :openai_compatible
    attribute :kind, :atom do
      allow_nil? false
      public? true
      default :openai_compatible
      constraints one_of: [:openai, :openai_compatible]
    end

    # The Responses API's built-in `web_search` tool runs inside the provider
    # (OpenAI); third-party providers don't have it and get standalone search.
    attribute :supports_hosted_web_search, :boolean,
      allow_nil?: false,
      default: false,
      public?: true

    # How long the gateway waits for the upstream to say anything (a model can
    # think for minutes before its first byte).
    attribute :request_timeout_ms, :integer do
      allow_nil? false
      public? true
      default 600_000
      constraints min: 1_000
    end

    # Requests allowed in flight at once against this provider; nil = no cap.
    # Beyond it the gateway answers 429 and codex backs off and retries.
    attribute :max_concurrent_requests, :integer do
      public? true
      constraints min: 1
    end

    attribute :last_checked_at, :utc_datetime_usec, public?: true
    attribute :last_error, :string, public?: true
    attribute :last_error_at, :utc_datetime_usec, public?: true

    timestamps public?: true
  end

  relationships do
    has_many :models, Longx.AI.Model
  end

  calculations do
    calculate :has_api_key?, :boolean, expr(not is_nil(encrypted_api_key)) do
      public? true
    end
  end

  identities do
    identity :unique_slug, [:slug]
  end

  @doc "The kind implied by a base URL: only OpenAI's own API is `:openai`."
  @spec kind_for_base_url(String.t() | nil) :: :openai | :openai_compatible
  def kind_for_base_url(base_url) when is_binary(base_url) do
    case URI.parse(base_url) do
      %URI{host: "api.openai.com"} -> :openai
      _ -> :openai_compatible
    end
  end

  def kind_for_base_url(_), do: :openai_compatible
end
