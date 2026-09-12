defmodule Longx.Projects.Turn do
  @moduledoc "One turn of a project thread with its git bookmarks. Placeholder until the next step fills it in."

  use Ash.Resource,
    otp_app: :longx,
    domain: Longx.Projects,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "project_turns"
    repo Longx.Repo
  end

  actions do
    defaults [:read, :destroy]
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :codex_turn_id, :string, allow_nil?: false, public?: true
    timestamps()
  end

  relationships do
    belongs_to :thread, Longx.Projects.Thread, allow_nil?: false, public?: true
  end

  identities do
    identity :unique_codex_turn_id, [:codex_turn_id]
  end
end
