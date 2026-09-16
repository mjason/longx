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
    data_layer: AshSqlite.DataLayer,
    extensions: [AshTypescript.Resource]

  alias Longx.Projects.Project.{Changes, Validations}

  sqlite do
    table "projects"
    repo Longx.Repo
    # writable_roots: the column was created (0.1.7) with a SQLite default of
    # '["~/.cache"]'; SQLite cannot alter a column default and Ash always
    # writes the attribute, so the generator is told to leave it alone
    migration_defaults writable_roots: "nil"
  end

  typescript do
    type_name "Project"
  end

  # what the SPA gets for git_info / init_git
  @git_info [
    repository: [type: :boolean, allow_nil?: false],
    head: [type: :string],
    clean: [type: :boolean],
    changes: [type: :integer, allow_nil?: false],
    lfs: [type: :boolean, allow_nil?: false]
  ]

  # what the SPA gets for codex_info: the home and the worker (nil = stopped)
  @codex_info [
    home: [type: :string, allow_nil?: false],
    exists: [type: :boolean, allow_nil?: false],
    bytes: [type: :integer, allow_nil?: false],
    files: [type: :map, allow_nil?: false],
    worker: [type: :map],
    # "models" / "config": what the running codex booted with has changed — restart it
    stale: [type: {:array, :string}, allow_nil?: false]
  ]

  actions do
    defaults [:read, :destroy]

    # what the UI calls: deliberate, and the home directory goes with the project
    destroy :delete do
      require_atomic? false
      argument :confirm, :boolean, default: false

      validate argument_equals(:confirm, true),
        message: "confirm: true is required to delete a project"

      change Changes.StopCodex
      change Changes.DeleteThreads
      change Changes.ResetCodexHome
      change Changes.DeleteAttachments
    end

    create :create do
      primary? true

      # the wizard's "initialise git" checkbox
      argument :init_git, :boolean, default: false

      # the slug is derived from the name (rename via update)
      accept [
        :name,
        :description,
        :root_path,
        :approval_policy,
        :sandbox,
        :tools,
        :dirty_start,
        :network_access,
        :writable_roots,
        :passthrough_paths,
        :web_search,
        :multi_agent,
        :auto_review,
        :global_memory,
        :memory_limit_mb,
        :model_id
      ]

      change Changes.NormalizeRootPath
      change Changes.DeriveSlug
      change Changes.InitGit
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
        :network_access,
        :writable_roots,
        :passthrough_paths,
        :web_search,
        :multi_agent,
        :auto_review,
        :global_memory,
        :memory_limit_mb,
        :model_id
      ]

      validate Validations.ToolsAreRegistered
    end

    update :archive do
      require_atomic? false
      change Changes.StopCodex
      change set_attribute(:archived_at, &DateTime.utc_now/0)
    end

    ## Generic actions the SPA calls (typed through ash_typescript)

    action :git_info, :map do
      constraints fields: @git_info
      argument :id, :uuid, allow_nil?: false
      run fn input, _ -> with {:ok, project} <- fetch(input), do: {:ok, git_info_map(project)} end
    end

    # the composer's @ mentions: codex's fuzzy file index under the root
    action :search_files, {:array, :map} do
      constraints items: [
                    fields: [
                      path: [type: :string, allow_nil?: false],
                      file_name: [type: :string, allow_nil?: false],
                      root: [type: :string, allow_nil?: false],
                      match_type: [type: :string, allow_nil?: false],
                      score: [type: :integer, allow_nil?: false],
                      indices: [type: {:array, :integer}]
                    ]
                  ]

      argument :id, :uuid, allow_nil?: false
      argument :query, :string, allow_nil?: false, constraints: [allow_empty?: true]

      run fn input, _ ->
        with {:ok, project} <- fetch(input),
             do: Longx.Projects.search_files(project, input.arguments.query)
      end
    end

    action :init_git, :map do
      constraints fields: @git_info
      argument :id, :uuid, allow_nil?: false

      run fn input, _ ->
        with {:ok, project} <- fetch(input),
             {:ok, _sha} <- Longx.Projects.init_git(project),
             do: {:ok, git_info_map(project)}
      end
    end

    action :codex_info, :map do
      constraints fields: @codex_info
      argument :id, :uuid, allow_nil?: false

      run fn input, _ ->
        with {:ok, project} <- fetch(input), do: {:ok, codex_info_map(project)}
      end
    end

    action :stop_codex do
      argument :id, :uuid, allow_nil?: false
      argument :force, :boolean, default: false

      run fn input, _ ->
        with {:ok, project} <- fetch(input),
             do: Longx.Projects.stop_codex(project, force: input.arguments.force)
      end
    end

    action :restart_codex do
      argument :id, :uuid, allow_nil?: false

      run fn input, _ ->
        with {:ok, project} <- fetch(input),
             {:ok, _pid} <- Longx.Projects.restart_codex(project),
             do: :ok
      end
    end

    action :clear_codex_history do
      argument :id, :uuid, allow_nil?: false

      run fn input, _ ->
        with {:ok, project} <- fetch(input), do: Longx.Projects.clear_codex_history(project)
      end
    end

    action :clear_codex_memories do
      argument :id, :uuid, allow_nil?: false

      run fn input, _ ->
        with {:ok, project} <- fetch(input), do: Longx.Projects.clear_codex_memories(project)
      end
    end

    action :reset_codex_home do
      argument :id, :uuid, allow_nil?: false

      run fn input, _ ->
        with {:ok, project} <- fetch(input), do: Longx.Projects.reset_codex_home(project)
      end
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

    # "ns.name" of Longx.Codex.Tool implementations offered on this project's
    # threads; empty = whatever is globally enabled (Longx.AI.enabled_tool_names/0)
    attribute :tools, {:array, :string}, allow_nil?: false, default: [], public?: true

    # What to do when a turn starts with uncommitted changes in a git project:
    # commit them first (every turn then starts from a commit), ask, or just record.
    attribute :dirty_start, :atom do
      allow_nil? false
      public? true
      default :commit
      constraints one_of: [:commit, :ask, :off]
    end

    # The workspace-write sandbox has no network unless the project says so
    # (codex `sandbox_workspace_write.network_access`); read-only and
    # danger-full-access ignore it.
    attribute :network_access, :boolean, allow_nil?: false, default: false, public?: true

    # Directories the workspace-write sandbox may write besides the project
    # and /tmp (codex `sandbox_workspace_write.writable_roots`); `~` is the
    # server user's home, a path that does not exist is skipped. Empty by
    # default — every entry widens the sandbox (a tool cache is where
    # planted code runs later, outside it), so each one is the person's
    # explicit choice. (A device cannot be let in this way: Longx.Codex.Sandbox.)
    attribute :writable_roots, {:array, :string}, allow_nil?: false, default: [], public?: true

    # Host paths let into the bubblewrap sandbox (Linux): device nodes (GPU,
    # USB, serial), a socket, a file — things codex's sandbox cannot show
    # (`--dev /dev` is a minimal device tree; codex has no device bind).
    # Globs allowed (`/dev/nvidia*`), resolved when codex starts. Bound by
    # Longx's bwrap wrapper (`Longx.Codex.Home`), leaving the filesystem and
    # network policy untouched. Each one weakens isolation in its own way —
    # a docker socket is host root; the UI says so. Empty by default.
    attribute :passthrough_paths, {:array, :string},
      allow_nil?: false,
      default: [],
      public?: true

    # Whether threads get codex's `web.run` (search + open URL, executed by
    # Longx's own gateway — this is separate from the sandbox's network,
    # which only governs commands). Decided at thread start.
    attribute :web_search, :boolean, allow_nil?: false, default: true, public?: true

    # codex's sub-agent tools (multi_agent_v2: spawn / wait / send / …) for
    # new threads; decided at thread start
    attribute :multi_agent, :boolean, allow_nil?: false, default: true, public?: true

    # codex's automatic approval review (Guardian): a permission request is
    # judged by a read-only reviewer session on the thread's model instead of
    # a card for the person; a denial can still be overridden in the chat.
    # Decided at thread start (`approvals_reviewer`).
    attribute :auto_review, :boolean, allow_nil?: false, default: true, public?: true

    # Longx's global memory (Longx.Memory) goes to every new thread as
    # developer instructions — unless this project wants none of it
    attribute :global_memory, :boolean, allow_nil?: false, default: true, public?: true

    # Optional cap on the codex process tree (Linux RLIMIT_AS / Windows Job
    # memory). Off by default: a task that needs 30 GB gets 30 GB; the OOM
    # ordering (Longx.Codex.Pool) protects the BEAM instead.
    attribute :memory_limit_mb, :integer do
      public? true
      constraints min: 64
    end

    attribute :archived_at, :utc_datetime_usec, public?: true

    timestamps public?: true
  end

  relationships do
    belongs_to :model, Longx.AI.Model, public?: true
    has_many :threads, Longx.Projects.Thread
  end

  # generic actions above resolve the project themselves (no record context)
  defp fetch(input), do: Ash.get(__MODULE__, input.arguments.id)

  defp git_info_map(project) do
    %{repository?: repo, head: head, clean?: clean, changes: changes, lfs?: lfs} =
      Longx.Projects.git_info(project)

    %{repository: repo, head: head, clean: clean, changes: changes, lfs: lfs}
  end

  defp codex_info_map(project) do
    info = Longx.Projects.codex_info(project)

    %{
      home: info.home,
      exists: info.exists?,
      bytes: info.bytes,
      files: info.files,
      worker: worker(info.worker),
      stale: Enum.map(info.stale, &Atom.to_string/1)
    }
  end

  defp worker(:stopped), do: nil

  defp worker(info),
    do:
      Map.take(info, [:phase, :started_at, :os_pid, :stats, :memory_limit, :turns, :active_turns])

  identities do
    identity :unique_slug, [:slug]
    identity :unique_root_path, [:root_path]
  end
end
