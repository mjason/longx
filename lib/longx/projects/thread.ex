defmodule Longx.Projects.Thread do
  @moduledoc "A codex thread that belongs to a project. Placeholder until the next step fills it in."

  use Ash.Resource,
    otp_app: :longx,
    domain: Longx.Projects,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "project_threads"
    repo Longx.Repo
  end

  actions do
    defaults [:read, :destroy]
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :codex_thread_id, :string, allow_nil?: false, public?: true
    timestamps()
  end

  relationships do
    belongs_to :project, Longx.Projects.Project, allow_nil?: false, public?: true
  end

  identities do
    identity :unique_codex_thread_id, [:codex_thread_id]
  end
end
