defmodule Longx.AI.Tool do
  @moduledoc """
  Whether a registered agent tool (`Longx.Codex.Tool`) may be offered to
  threads. The registry is the catalogue of what *exists* in the code; this
  row is the switch. New tools appear disabled — nothing reaches a thread
  unless someone turns it on globally here or picks it when starting the
  thread (`Longx.Codex.Thread.start/1`, `tools:`).

  Rows are mirrored from the registry by `Longx.AI.list_tools/0`; description
  and schema are read from the code, never stored.
  """

  use Ash.Resource,
    otp_app: :longx,
    domain: Longx.AI,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "ai_tools"
    repo Longx.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:namespace, :name, :enabled]
      upsert? true
      upsert_identity :unique_qualified_name
      # a re-sync must never flip an existing switch
      upsert_fields []
    end

    update :set_enabled do
      accept [:enabled]
    end

    read :by_qualified_name do
      argument :namespace, :string, allow_nil?: false
      argument :name, :string, allow_nil?: false
      get? true
      filter expr(namespace == ^arg(:namespace) and name == ^arg(:name))
    end

    read :enabled do
      filter expr(enabled == true)
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :namespace, :string, allow_nil?: false, public?: true
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :enabled, :boolean, allow_nil?: false, default: false, public?: true
    timestamps()
  end

  identities do
    identity :unique_qualified_name, [:namespace, :name]
  end
end
