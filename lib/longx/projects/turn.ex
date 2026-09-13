defmodule Longx.Projects.Turn do
  @moduledoc """
  One turn of a project thread with its git bookmarks: the commit the
  working tree was at when the turn started (`commit_before`, after any
  dirty-start commit) and when it finished (`commit_after`). Those are what
  "go back to before turn N" restores to. Codex's per-turn diff is kept for
  display.
  """

  use Ash.Resource,
    otp_app: :longx,
    domain: Longx.Projects,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshTypescript.Resource]

  sqlite do
    table "project_turns"
    repo Longx.Repo
  end

  typescript do
    type_name "Turn"
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :codex_turn_id,
        :thread_id,
        :user_text,
        :model_slug,
        :commit_before,
        :dirty_start,
        :started_at
      ]
    end

    update :complete do
      accept [:status, :completed_at, :commit_after, :error]
    end

    update :set_diff do
      accept [:diff]
    end

    # the turn was removed from the conversation by a redo; kept for the record
    read :in_progress_for_project do
      argument :project_id, :uuid, allow_nil?: false
      filter expr(status == :in_progress and thread.project_id == ^arg(:project_id))
    end

    update :mark_reverted do
      change set_attribute(:status, :reverted)
    end

    read :by_codex_id do
      argument :codex_turn_id, :string, allow_nil?: false
      get? true
      filter expr(codex_turn_id == ^arg(:codex_turn_id))
    end

    read :for_thread do
      argument :thread_id, :uuid, allow_nil?: false
      argument :include_reverted, :boolean, default: false

      filter expr(
               thread_id == ^arg(:thread_id) and (^arg(:include_reverted) or status != :reverted)
             )

      prepare build(sort: [started_at: :asc, inserted_at: :asc])
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :codex_turn_id, :string, allow_nil?: false, public?: true
    attribute :user_text, :string, public?: true
    attribute :model_slug, :string, public?: true

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :in_progress
      constraints one_of: [:in_progress, :completed, :failed, :interrupted, :reverted]
    end

    attribute :started_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :completed_at, :utc_datetime_usec, public?: true

    # git bookmarks; nil when the project is not a repository
    attribute :commit_before, :string, public?: true
    attribute :commit_after, :string, public?: true
    # the tree had uncommitted changes when the turn started and they were not committed
    attribute :dirty_start, :boolean, allow_nil?: false, default: false, public?: true

    attribute :diff, :string, public?: true
    attribute :error, :string, public?: true

    timestamps public?: true
  end

  relationships do
    belongs_to :thread, Longx.Projects.Thread, allow_nil?: false, public?: true
  end

  identities do
    identity :unique_codex_turn_id, [:codex_turn_id]
  end
end
