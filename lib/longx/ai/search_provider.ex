defmodule Longx.AI.SearchProvider do
  @moduledoc """
  A web-search backend for the kernel's standalone `web_search` tool
  (`Longx.AI.Search`). The API key is encrypted at
  rest like `Longx.AI.Provider`'s. Only Tavily for now; `kind` is an enum so
  Brave & co. can follow without a migration.
  """

  use Ash.Resource,
    otp_app: :longx,
    domain: Longx.AI,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshCloak, AshTypescript.Resource]

  sqlite do
    table "ai_search_providers"
    repo Longx.Repo
  end

  cloak do
    vault(Longx.Vault)
    attributes([:api_key])
    decrypt_by_default([])
    encrypt_nil?(false)
  end

  typescript do
    type_name "SearchProvider"
    field_names has_api_key?: "hasApiKey"
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:name, :slug, :kind, :base_url, :api_key]
    end

    update :update do
      primary? true
      accept [:name, :base_url, :api_key]
    end

    read :by_slug do
      argument :slug, :string, allow_nil?: false
      get? true
      filter expr(slug == ^arg(:slug))
    end

    read :default do
      get? true
      filter expr(default == true)
    end

    update :make_default do
      require_atomic? false
      change set_attribute(:default, true)
      change Longx.AI.SearchProvider.Changes.ClearOtherDefaults
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

    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:tavily]
    end

    attribute :base_url, :string do
      allow_nil? false
      public? true
      default "https://api.tavily.com"
    end

    attribute :api_key, :string, sensitive?: true
    attribute :default, :boolean, allow_nil?: false, default: false, public?: true

    timestamps()
  end

  calculations do
    calculate :has_api_key?, :boolean, expr(not is_nil(encrypted_api_key)) do
      public? true
    end
  end

  identities do
    identity :unique_slug, [:slug]
  end
end
