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

  # what restore_proposal/1 shows before anyone touches the tree
  @restore_proposal [
    commit: [type: :string, allow_nil?: false],
    dirty_now: [type: :boolean, allow_nil?: false],
    changed_files: [type: {:array, :string}, allow_nil?: false],
    later_turns: [type: :integer, allow_nil?: false]
  ]

  @restore_result [
    safety_commit: [type: :string],
    head: [type: :string, allow_nil?: false]
  ]

  actions do
    defaults [:read, :destroy]

    ## Generic actions the SPA calls; the work is in Longx.Projects

    action :restore_proposal, :map do
      constraints fields: @restore_proposal
      argument :turn_id, :uuid, allow_nil?: false

      run fn input, _ ->
        with {:ok, turn} <- Ash.get(__MODULE__, input.arguments.turn_id),
             {:ok, proposal} <- Longx.Projects.restore_proposal(turn) do
          {:ok,
           %{
             commit: proposal.commit,
             dirty_now: proposal.dirty_now?,
             changed_files: proposal.changed_files,
             later_turns: proposal.later_turns
           }}
        end
      end
    end

    # files back to before this turn; never without confirm
    action :restore_files, :map do
      constraints fields: @restore_result
      argument :turn_id, :uuid, allow_nil?: false
      argument :confirm, :boolean, default: false
      argument :mode, :atom, constraints: [one_of: [:restore_tree, :reset_hard]]

      run fn input, _ ->
        opts =
          input.arguments
          |> Map.take([:confirm, :mode])
          |> Enum.reject(fn {_, v} -> is_nil(v) end)

        with {:ok, turn} <- Ash.get(__MODULE__, input.arguments.turn_id),
             do: Longx.Projects.restore_files(turn, opts)
      end
    end

    # this turn again — other text and/or model; :revert drops it and what
    # followed from the conversation, :fork starts a sibling thread before it
    action :redo_turn, :struct do
      constraints instance_of: __MODULE__
      argument :turn_id, :uuid, allow_nil?: false
      argument :text, :string
      argument :model, :string
      argument :mode, :atom, constraints: [one_of: [:revert, :fork]]
      argument :restore_files, :boolean

      run fn input, _ ->
        opts =
          input.arguments
          |> Map.take([:text, :model, :mode, :restore_files])
          |> Enum.reject(fn {_, v} -> is_nil(v) end)

        with {:ok, turn} <- Ash.get(__MODULE__, input.arguments.turn_id),
             do: Longx.Projects.redo_turn(turn, opts)
      end
    end

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
