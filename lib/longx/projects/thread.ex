defmodule Longx.Projects.Thread do
  @moduledoc """
  A codex thread that belongs to a project: the mapping to codex's own id
  plus the settings the thread was actually started with (so a resume uses
  the same ones) and the little metadata a list needs. The conversation
  itself lives in codex's store and, while live, in `Longx.Codex.ThreadState`.
  """

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

    create :create do
      primary? true

      accept [
        :codex_thread_id,
        :project_id,
        :cwd,
        :model_slug,
        :approval_policy,
        :sandbox,
        :tools,
        :forked_from_id
      ]
    end

    update :touch do
      accept [:status, :preview, :model_slug, :last_activity_at]
    end

    update :rename do
      accept [:title]
    end

    update :archive do
      change set_attribute(:status, :archived)
    end

    read :by_codex_id do
      argument :codex_thread_id, :string, allow_nil?: false
      get? true
      filter expr(codex_thread_id == ^arg(:codex_thread_id))
    end

    read :for_project do
      argument :project_id, :uuid, allow_nil?: false
      filter expr(project_id == ^arg(:project_id) and status != :archived)
      prepare build(sort: [last_activity_at: :desc_nils_last, inserted_at: :desc])
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :codex_thread_id, :string, allow_nil?: false, public?: true
    attribute :title, :string, public?: true
    attribute :preview, :string, public?: true

    # working directory codex was given (the project root, or a worktree later)
    attribute :cwd, :string, allow_nil?: false, public?: true

    # settings at start; nil model = codex's placeholder (global default)
    attribute :model_slug, :string, public?: true

    attribute :approval_policy, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:never, :on_request, :untrusted]
    end

    attribute :sandbox, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:read_only, :workspace_write, :danger_full_access]
    end

    attribute :tools, {:array, :string}, allow_nil?: false, default: [], public?: true

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :idle
      constraints one_of: [:idle, :active, :archived]
    end

    attribute :last_activity_at, :utc_datetime_usec, public?: true

    timestamps()
  end

  relationships do
    belongs_to :project, Longx.Projects.Project, allow_nil?: false, public?: true
    # set when this thread was created by a redo in fork mode
    belongs_to :forked_from, Longx.Projects.Thread, public?: true
    has_many :turns, Longx.Projects.Turn
  end

  identities do
    identity :unique_codex_thread_id, [:codex_thread_id]
  end
end
