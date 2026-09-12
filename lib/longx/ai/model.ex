defmodule Longx.AI.Model do
  @moduledoc """
  A model offered by a `Longx.AI.Provider`. `upstream_id` is what the
  provider expects in the request's `model` field. `slug` is the name codex
  sees (per thread / per turn via `model:`); the gateway maps it back. The
  placeholder `longx` means "the global default model" and is reserved.
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
      accept [:name, :slug, :upstream_id, :context_window, :provider_id]
      change Longx.AI.Model.Changes.DeriveSlug
    end

    update :update do
      primary? true
      accept [:name, :slug, :upstream_id, :context_window]
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

    # Exactly one model is the default: clear the flag everywhere else first.
    update :make_default do
      require_atomic? false
      change set_attribute(:default, true)
      change Longx.AI.Model.Changes.ClearOtherDefaults
    end
  end

  validations do
    validate present(:slug), where: [changing(:slug)]

    # "longx" is what codex is configured with; it means the global default
    # (Longx.AI.placeholder_model/0 — a literal here to avoid a compile cycle)
    validate compare(:slug, is_not_equal: "longx"),
      message: "is reserved for the global default",
      where: [changing(:slug)]
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string, allow_nil?: false, public?: true
    # nullable in the DB only because SQLite cannot add a NOT NULL column later;
    # DeriveSlug + the identity make it effectively required and unique
    attribute :slug, :string, public?: true
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

  identities do
    identity :unique_slug, [:slug]
  end
end
