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
      # the reasoning level to start on (absent: the model's default)
      argument :effort, :string
      argument :tools, {:array, :string}
      argument :approval_policy, :atom, constraints: [one_of: [:never, :on_request, :untrusted]]

      argument :sandbox, :atom,
        constraints: [one_of: [:read_only, :workspace_write, :danger_full_access]]

      argument :network_access, :boolean
      argument :web_search, :boolean
      argument :multi_agent, :boolean
      argument :auto_review, :boolean

      run fn input, _ ->
        opts =
          input.arguments
          |> Map.take([
            :model,
            :effort,
            :tools,
            :approval_policy,
            :sandbox,
            :network_access,
            :web_search,
            :multi_agent,
            :auto_review
          ])
          |> Enum.reject(fn {_, v} -> is_nil(v) end)

        with {:ok, project} <- Ash.get(Longx.Projects.Project, input.arguments.project_id),
             do: project |> Longx.Projects.start_thread(opts) |> model_errors()
      end
    end

    action :send_message, :struct do
      constraints instance_of: Longx.Projects.Turn
      argument :thread_id, :uuid, allow_nil?: false
      argument :text, :string, allow_nil?: false
      # the composer's image attachments, as data: urls
      argument :images, {:array, :string}
      argument :model, :string
      # the reasoning level from this turn on (absent: the thread keeps its level)
      argument :effort, :string
      # what to do with a dirty tree when the project's policy is :ask
      argument :dirty, :atom, constraints: [one_of: [:commit, :ignore]]
      # the access mode from this turn on (absent: the thread keeps its mode)
      argument :sandbox, :atom,
        constraints: [one_of: [:read_only, :workspace_write, :danger_full_access]]

      argument :approval_policy, :atom, constraints: [one_of: [:never, :on_request, :untrusted]]
      argument :network_access, :boolean

      run fn input, _ ->
        opts =
          input.arguments
          |> Map.take([
            :images,
            :model,
            :effort,
            :dirty,
            :sandbox,
            :approval_policy,
            :network_access
          ])
          |> Enum.reject(fn {_, v} -> is_nil(v) end)

        with {:ok, thread} <- Ash.get(__MODULE__, input.arguments.thread_id) do
          case Longx.Projects.send_message(thread, input.arguments.text, opts) do
            {:error, {:dirty_tree, changes}} ->
              {:error, Longx.Projects.Errors.DirtyTree.exception(changes: changes)}

            other ->
              model_errors(other)
          end
        end
      end
    end

    # /compact: codex folds the context (never while a turn runs)
    action :compact_thread do
      argument :thread_id, :uuid, allow_nil?: false

      run fn input, _ ->
        with {:ok, thread} <- Ash.get(__MODULE__, input.arguments.thread_id) do
          case Longx.Projects.compact_thread(thread) do
            :ok ->
              :ok

            {:error, :turn_in_progress} ->
              argument_error(:thread_id, "a turn is running")

            {:error, other} ->
              {:error, other}
          end
        end
      end
    end

    # /review: codex reviews the uncommitted changes, a commit, or the diff
    # against a branch, as a turn of this thread
    action :review_thread, :struct do
      constraints instance_of: Longx.Projects.Turn
      argument :thread_id, :uuid, allow_nil?: false

      argument :target, :atom,
        allow_nil?: false,
        constraints: [one_of: [:uncommitted, :commit, :base_branch, :custom]]

      # the sha, branch name or instructions the target needs
      argument :value, :string

      run fn input, _ ->
        with {:ok, thread} <- Ash.get(__MODULE__, input.arguments.thread_id),
             {:ok, target} <- review_target(input.arguments) do
          case Longx.Projects.review_thread(thread, target) do
            {:error, :turn_in_progress} ->
              argument_error(:thread_id, "a turn is running")

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

    # the row and its turns go; codex's own copy of the conversation stays
    # in its sqlite (clear_codex_history is the project-level wipe)
    action :delete_thread do
      argument :thread_id, :uuid, allow_nil?: false

      run fn input, _ ->
        with {:ok, thread} <- Ash.get(__MODULE__, input.arguments.thread_id),
             do: Longx.Projects.delete_thread(thread)
      end
    end

    # answers a question codex asked (item/tool/requestUserInput): the raw
    # response map, `%{"answers" => %{question_id => %{"answers" => [..]}}}`
    action :answer_request do
      argument :thread_id, :uuid, allow_nil?: false
      argument :request_id, :string, allow_nil?: false
      argument :answers, :map, allow_nil?: false

      run fn input, _ ->
        with {:ok, thread} <- Ash.get(__MODULE__, input.arguments.thread_id) do
          Longx.Codex.Thread.respond_raw(
            input.arguments.request_id,
            %{"answers" => input.arguments.answers},
            thread_id: thread.codex_thread_id
          )
        end
      end
    end

    # overrides a denial of codex's automatic approval review: the action is
    # handed back as approved by the person (the model may retry it next turn)
    action :approve_review do
      argument :thread_id, :uuid, allow_nil?: false
      argument :review_id, :string, allow_nil?: false

      run fn input, _ ->
        with {:ok, thread} <- Ash.get(__MODULE__, input.arguments.thread_id),
             :ok <- Longx.Projects.approve_denied_review(thread, input.arguments.review_id) do
          :ok
        else
          {:error, :not_found} ->
            invalid_review("no denied review with this id")

          {:error, :not_denied} ->
            invalid_review("this review was not denied")

          # codex refused the event (its shape is ours to get right) or is gone
          {:error, %Longx.Codex.Error{message: message}} ->
            invalid_review("codex refused the approval: #{message}")

          {:error, reason} ->
            invalid_review("could not approve: #{inspect(reason)}")
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
        :reasoning_effort,
        :approval_policy,
        :sandbox,
        :network_access,
        :web_search,
        :multi_agent,
        :auto_review,
        :tools,
        :forked_from_id,
        :parent_thread_id,
        :agent_path,
        :title,
        :status
      ]
    end

    update :touch do
      accept [
        :status,
        :preview,
        :title,
        :model_slug,
        :reasoning_effort,
        :last_activity_at,
        :sandbox,
        :approval_policy,
        :network_access
      ]
    end

    # the memory pipeline read this thread's rollout up to its last activity
    update :mark_extracted do
      change set_attribute(:memory_extracted_at, &DateTime.utc_now/0)
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

      filter expr(
               project_id == ^arg(:project_id) and status != :archived and
                 is_nil(parent_thread_id)
             )

      prepare build(sort: [last_activity_at: :desc_nils_last, inserted_at: :desc])
    end

    # the sub-agents codex spawned inside a thread's conversation
    read :subagents_of do
      argument :parent_thread_id, :uuid, allow_nil?: false
      filter expr(parent_thread_id == ^arg(:parent_thread_id))
      prepare build(sort: [inserted_at: :asc])
    end

    read :with_status do
      argument :project_id, :uuid, allow_nil?: false
      argument :status, :atom, allow_nil?: false
      filter expr(project_id == ^arg(:project_id) and status == ^arg(:status))
    end
  end

  # what the model-choosing actions answer when the choice is bad: an error
  # on the argument, not "something went wrong"
  @doc false
  def model_errors({:error, {:unknown_model, slug}}),
    do: argument_error(:model, "未知的模型 #{slug}")

  def model_errors({:error, {:unknown_effort, effort}}),
    do: argument_error(:effort, "这个模型没有 #{effort} 这一档")

  def model_errors({:error, :no_default_model}),
    do: argument_error(:model, "还没有默认模型，先在设置里选一个")

  def model_errors(other), do: other

  # an error on one argument, the way the client shows it next to the field
  # (a bare `{:error, field: …}` from a generic action's run is "unknown")
  @doc false
  def argument_error(field, message) do
    {:error,
     Ash.Error.to_error_class(
       Ash.Error.Changes.InvalidArgument.exception(field: field, message: message)
     )}
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
    # the reasoning level the thread runs with now: chosen at start or by a
    # turn, else the model's default when it started (nil: codex's default)
    attribute :reasoning_effort, :string, public?: true

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

    # the workspace-write sandbox has no network unless this is true
    attribute :network_access, :boolean, allow_nil?: false, default: false, public?: true

    # codex's web.run offered to this thread (fixed at start: a thread/start config)
    attribute :web_search, :boolean, allow_nil?: false, default: true, public?: true

    # codex's sub-agent tools offered to this thread (fixed at start)
    attribute :multi_agent, :boolean, allow_nil?: false, default: true, public?: true

    # codex's automatic approval review on this thread (fixed at start)
    attribute :auto_review, :boolean, allow_nil?: false, default: true, public?: true

    # a sub-agent spawned by codex inside `parent_thread_id`'s conversation:
    # codex's agent path ("/root/reader_a"); such threads never show in the
    # project's list, they belong to their parent's view
    attribute :agent_path, :string, public?: true

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
    # when Longx.Memory.Extract last distilled this thread (nil: never)
    attribute :memory_extracted_at, :utc_datetime_usec, public?: true

    timestamps public?: true
  end

  relationships do
    belongs_to :project, Longx.Projects.Project, allow_nil?: false, public?: true
    # set when this thread was created by a redo in fork mode
    belongs_to :forked_from, Longx.Projects.Thread, public?: true
    belongs_to :parent_thread, Longx.Projects.Thread, public?: true
    has_many :turns, Longx.Projects.Turn
  end

  identities do
    identity :unique_codex_thread_id, [:codex_thread_id]
  end

  defp review_target(%{target: :uncommitted}), do: {:ok, :uncommitted}

  defp review_target(%{target: kind, value: value}) when is_binary(value) and value != "",
    do: {:ok, {kind, value}}

  defp review_target(_), do: argument_error(:value, "is required for this target")

  defp invalid_review(message) do
    {:error,
     Ash.Error.Invalid.exception(
       errors: [%Ash.Error.Changes.InvalidArgument{field: :review_id, message: message}]
     )}
  end
end
