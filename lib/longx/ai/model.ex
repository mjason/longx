defmodule Longx.AI.Model do
  @moduledoc """
  A model offered by a `Longx.AI.Provider`. `upstream_id` is what the
  provider expects in the request's `model` field; codex itself only ever
  sees the placeholder model `longx` and the gateway substitutes this.
  """

  use Ash.Resource,
    otp_app: :longx,
    domain: Longx.AI,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "ai_models"
    repo Longx.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:name, :upstream_id, :context_window, :provider_id]
    end

    update :update do
      primary? true
      accept [:name, :upstream_id, :context_window]
    end

    read :default do
      get? true
      filter expr(default == true)
    end

    # Exactly one model is the default: clear the flag everywhere else first.
    update :make_default do
      require_atomic? false
      change set_attribute(:default, true)
      change Longx.AI.Model.Changes.ClearOtherDefaults
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string, allow_nil?: false, public?: true
    attribute :upstream_id, :string, allow_nil?: false, public?: true

    attribute :context_window, :integer do
      public? true
      allow_nil? false
      default 128_000
      constraints min: 1
    end

    attribute :default, :boolean, allow_nil?: false, default: false, public?: true

    timestamps()
  end

  relationships do
    belongs_to :provider, Longx.AI.Provider, allow_nil?: false, public?: true
  end
end
