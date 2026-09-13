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
    data_layer: AshSqlite.DataLayer,
    extensions: [AshTypescript.Resource]

  sqlite do
    table "project_threads"
    repo Longx.Repo
  end

  typescript do
    type_name "Thread"
  end

  actions do
    defaults [:read, :destroy]

    ## Generic actions the SPA calls; the work is in Longx.Projects

    action :start_thread, :struct do
      constraints instance_of: __MODULE__
      argument :project_id, :uuid, allow_nil?: false
      argument :model, :string
      argument :tools, {:array, :string}
      argument :approval_policy, :atom, constraints: [one_of: [:never, :on_request, :untrusted]]

      argument :sandbox, :atom,
        constraints: [one_of: [:read_only, :workspace_write, :danger_full_access]]

      run fn input, _ ->
        opts =
          input.arguments
          |> Map.take([:model, :tools, :approval_policy, :sandbox])
          |> Enum.reject(fn {_, v} -> is_nil(v) end)

        with {:ok, project} <- Ash.get(Longx.Projects.Project, input.arguments.project_id),
             do: Longx.Projects.start_thread(project, opts)
      end
    end

    action :send_message, :struct do
      constraints instance_of: Longx.Projects.Turn
      argument :thread_id, :uuid, allow_nil?: false
      argument :text, :string, allow_nil?: false
      argument :model, :string
      # what to do with a dirty tree when the project's policy is :ask
      argument :dirty, :atom, constraints: [one_of: [:commit, :ignore]]

      run fn input, _ ->
        opts =
          input.arguments
          |> Map.take([:model, :dirty])
          |> Enum.reject(fn {_, v} -> is_nil(v) end)

        with {:ok, thread} <- Ash.get(__MODULE__, input.arguments.thread_id) do
          case Longx.Projects.send_message(thread, input.arguments.text, opts) do
            {:error, {:dirty_tree, changes}} ->
              {:error, Longx.Projects.Errors.DirtyTree.exception(changes: changes)}

            other ->
              other
          end
        end
      end
    end

    # stops the turn in flight (the composer's stop button)
    action :interrupt_turn do
      argument :thread_id, :uuid, allow_nil?: false
      argument :codex_turn_id, :string, allow_nil?: false

      run fn input, _ ->
        with {:ok, thread} <- Ash.get(__MODULE__, input.arguments.thread_id),
             do:
               Longx.Codex.Thread.interrupt(thread.codex_thread_id, input.arguments.codex_turn_id)
      end
    end

    # answers a pending approval shown in the thread's snapshot
    action :respond do
      argument :thread_id, :uuid, allow_nil?: false
      argument :request_id, :string, allow_nil?: false

      argument :decision, :atom,
        allow_nil?: false,
        constraints: [one_of: [:accept, :accept_for_session, :decline, :cancel]]

      run fn input, _ ->
        with {:ok, thread} <- Ash.get(__MODULE__, input.arguments.thread_id) do
          Longx.Codex.Thread.respond(input.arguments.request_id, input.arguments.decision,
            thread_id: thread.codex_thread_id
          )
        end
      end
    end

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

    # an empty thread codex could not resume was started again (new codex id)
    update :rehost do
      accept [:codex_thread_id]
      change set_attribute(:status, :idle)
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

    read :with_status do
      argument :project_id, :uuid, allow_nil?: false
      argument :status, :atom, allow_nil?: false
      filter expr(project_id == ^arg(:project_id) and status == ^arg(:status))
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
      # :disconnected — its codex died; resumed (→ :idle) when it is back
      # :unrecoverable — codex no longer knows it; history is gone
      constraints one_of: [:idle, :active, :disconnected, :unrecoverable, :archived]
    end

    attribute :last_activity_at, :utc_datetime_usec, public?: true

    timestamps public?: true
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
