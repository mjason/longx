defmodule Longx.Projects.Turn do
  @moduledoc """
  One turn of a project thread: what was sent, on which model and level,
  when it started and ended, how it ended, what it cost. Nothing of git:
  the working tree is the person's (the per-turn bookmarks and restore
  points of 0.2.x are gone).
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
        :kernel_turn_id,
        :thread_id,
        :user_text,
        :model_slug,
        :reasoning_effort,
        :started_at
      ]
    end

    update :complete do
      accept [:status, :completed_at, :error, :usage]
    end

    # the turn was removed from the conversation by a redo; kept for the record
    read :in_progress_for_project do
      argument :project_id, :uuid, allow_nil?: false
      filter expr(status == :in_progress and thread.project_id == ^arg(:project_id))
    end

    read :in_progress do
      filter expr(status == :in_progress)
    end

    update :mark_reverted do
      change set_attribute(:status, :reverted)
    end

    read :by_kernel_id do
      argument :kernel_turn_id, :string, allow_nil?: false
      get? true
      filter expr(kernel_turn_id == ^arg(:kernel_turn_id))
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

    attribute :kernel_turn_id, :string, allow_nil?: false, public?: true
    attribute :user_text, :string, public?: true
    attribute :model_slug, :string, public?: true
    # the reasoning level in force for this turn
    attribute :reasoning_effort, :string, public?: true

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :in_progress
      constraints one_of: [:in_progress, :completed, :failed, :interrupted, :reverted]
    end

    attribute :started_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :completed_at, :utc_datetime_usec, public?: true

    attribute :error, :string, public?: true
    # the turn's own token usage (inputTokens, cachedInputTokens, outputTokens,
    # reasoningOutputTokens, totalTokens) — the per-turn badge, kept across restarts
    attribute :usage, :map, public?: true

    timestamps public?: true
  end

  relationships do
    belongs_to :thread, Longx.Projects.Thread, allow_nil?: false, public?: true
  end

  identities do
    identity :unique_kernel_turn_id, [:kernel_turn_id]
  end
end
