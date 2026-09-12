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
    extensions: [AshCloak]

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

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:name, :slug, :kind, :base_url, :api_key, :supports_hosted_web_search]
    end

    update :update do
      primary? true
      accept [:name, :kind, :base_url, :api_key, :supports_hosted_web_search]
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

    timestamps()
  end

  relationships do
    has_many :models, Longx.AI.Model
  end

  calculations do
    calculate :has_api_key?, :boolean, expr(not is_nil(encrypted_api_key))
  end

  identities do
    identity :unique_slug, [:slug]
  end
end
