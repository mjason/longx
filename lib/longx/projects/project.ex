defmodule Longx.Projects.Project do
  @moduledoc """
  A project is a working directory the agent operates in, plus the defaults
  every thread started in it inherits: approval policy, sandbox, the Elixir
  tools it may use, the model (nil → global default) and what to do when a
  turn starts on a dirty git tree.

  `root_path` is absolute, must exist, and is unique: one project per
  directory. Whether it is a git repository is read live (`Longx.Projects.git_info/1`),
  never stored.
  """

  use Ash.Resource,
    otp_app: :longx,
    domain: Longx.Projects,
    data_layer: AshSqlite.DataLayer

  alias Longx.Projects.Project.{Changes, Validations}

  sqlite do
    table "projects"
    repo Longx.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :name,
        :slug,
        :description,
        :root_path,
        :approval_policy,
        :sandbox,
        :tools,
        :dirty_start,
        :model_id
      ]

      change Changes.NormalizeRootPath
      change Changes.DeriveSlug
      validate Validations.RootPathIsDirectory
      validate Validations.ToolsAreRegistered
    end

    update :update do
      primary? true
      require_atomic? false

      accept [
        :name,
        :slug,
        :description,
        :approval_policy,
        :sandbox,
        :tools,
        :dirty_start,
        :model_id
      ]

      validate Validations.ToolsAreRegistered
    end

    update :archive do
      change set_attribute(:archived_at, &DateTime.utc_now/0)
    end

    read :by_slug do
      argument :slug, :string, allow_nil?: false
      get? true
      filter expr(slug == ^arg(:slug))
    end

    read :active do
      filter expr(is_nil(archived_at))
      prepare build(sort: [updated_at: :desc])
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string, allow_nil?: false, public?: true
    attribute :slug, :string, allow_nil?: false, public?: true
    attribute :description, :string, public?: true

    attribute :root_path, :string, allow_nil?: false, public?: true

    attribute :approval_policy, :atom do
      allow_nil? false
      public? true
      default :on_request
      constraints one_of: [:never, :on_request, :untrusted]
    end

    attribute :sandbox, :atom do
      allow_nil? false
      public? true
      default :workspace_write
      constraints one_of: [:read_only, :workspace_write, :danger_full_access]
    end

    # "ns.name" of Longx.Codex.Tool implementations offered on this project's threads
    attribute :tools, {:array, :string}, allow_nil?: false, default: [], public?: true

    # What to do when a turn starts with uncommitted changes in a git project:
    # commit them first (every turn then starts from a commit), ask, or just record.
    attribute :dirty_start, :atom do
      allow_nil? false
      public? true
      default :commit
      constraints one_of: [:commit, :ask, :off]
    end

    attribute :archived_at, :utc_datetime_usec, public?: true

    timestamps()
  end

  relationships do
    belongs_to :model, Longx.AI.Model, public?: true
    has_many :threads, Longx.Projects.Thread
  end

  identities do
    identity :unique_slug, [:slug]
    identity :unique_root_path, [:root_path]
  end
end
