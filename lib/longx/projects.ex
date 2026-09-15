defmodule Longx.Projects do
  @moduledoc """
  Projects (working directories with defaults), the codex threads run in
  them, and each thread's turns with their git bookmarks. Git is the safety
  net: this domain tells the UI when a project has none, can set it up, and
  records the commit every turn started from so a bad turn can be undone.
  """

  use Ash.Domain, otp_app: :longx, extensions: [AshTypescript.Rpc]

  alias Longx.Git
  alias Longx.Projects.Project

  # The SPA's typed client (assets/js/ash_rpc.ts, `mix ash_typescript.codegen`)
  typescript_rpc do
    resource Project do
      rpc_action :list_projects, :active
      rpc_action :list_all_projects, :read
      rpc_action :get_project, :by_slug
      rpc_action :create_project, :create
      rpc_action :update_project, :update
      rpc_action :archive_project, :archive
      rpc_action :delete_project, :delete
      rpc_action :git_info, :git_info
      rpc_action :search_files, :search_files
      rpc_action :init_git, :init_git
      rpc_action :codex_info, :codex_info
      rpc_action :stop_codex, :stop_codex
      rpc_action :restart_codex, :restart_codex
      rpc_action :clear_codex_history, :clear_codex_history
      rpc_action :clear_codex_memories, :clear_codex_memories
      rpc_action :reset_codex_home, :reset_codex_home
    end

    resource Longx.Projects.Thread do
      rpc_action :list_threads, :for_project
      rpc_action :list_subagents, :subagents_of
      rpc_action :start_thread, :start_thread
      rpc_action :send_message, :send_message
      rpc_action :interrupt_turn, :interrupt_turn
      rpc_action :compact_thread, :compact_thread
      rpc_action :review_thread, :review_thread
      rpc_action :respond, :respond
      rpc_action :answer_request, :answer_request
      rpc_action :rename_thread, :rename
      rpc_action :archive_thread, :archive
      rpc_action :delete_thread, :delete_thread
    end

    resource Longx.Projects.Files do
      rpc_action :list_files, :list_files
      rpc_action :read_file, :read_file
      rpc_action :write_file, :write_file
      rpc_action :create_entry, :create_entry
      rpc_action :rename_entry, :rename_entry
      rpc_action :delete_entry, :delete_entry
    end

    resource Longx.Projects.Repo do
      rpc_action :git_changes, :git_changes
      rpc_action :git_file_diff, :git_file_diff
      rpc_action :git_commit, :git_commit
      rpc_action :git_discard, :git_discard
      rpc_action :git_undo_commit, :git_undo_commit
      rpc_action :git_abort_merge, :git_abort_merge
      rpc_action :git_log, :git_log
      rpc_action :git_show, :git_show
      rpc_action :git_commit_file_diff, :git_commit_file_diff
      rpc_action :git_file_versions, :git_file_versions
      rpc_action :git_branches, :git_branches
      rpc_action :git_create_branch, :git_create_branch
      rpc_action :git_switch, :git_switch
      rpc_action :git_delete_branch, :git_delete_branch
      rpc_action :git_stash_pop, :git_stash_pop
      rpc_action :git_set_remote, :git_set_remote
      rpc_action :git_fetch, :git_fetch
      rpc_action :git_pull, :git_pull
      rpc_action :git_push, :git_push
    end

    resource Longx.Projects.Turn do
      rpc_action :list_turns, :for_thread
      rpc_action :restore_proposal, :restore_proposal
      rpc_action :restore_files, :restore_files
      rpc_action :redo_turn, :redo_turn
    end
  end

  resources do
    resource Project do
      define :create_project, action: :create
      define :update_project, action: :update
      define :archive_project, action: :archive
      define :get_project_by_slug, action: :by_slug, args: [:slug]
      define :list_active_projects, action: :active
      define :list_all_projects, action: :read
    end

    resource Longx.Projects.Thread do
      define :create_thread, action: :create
      define :touch_thread, action: :touch
      define :mark_thread_extracted, action: :mark_extracted
      define :rename_thread, action: :rename
      define :archive_thread, action: :archive
      define :get_thread_by_codex_id, action: :by_codex_id, args: [:codex_thread_id]
      define :rehost_thread, action: :rehost
      define :list_threads_for_project, action: :for_project, args: [:project_id]
      define :list_threads_with_status, action: :with_status, args: [:project_id, :status]
      define :list_subagents, action: :subagents_of, args: [:parent_thread_id]
    end

    resource Longx.Projects.Files
    resource Longx.Projects.Repo

    resource Longx.Projects.Turn do
      define :create_turn, action: :create
      define :complete_turn, action: :complete
      define :set_turn_diff, action: :set_diff
      define :mark_turn_reverted, action: :mark_reverted
      define :get_turn_by_codex_id, action: :by_codex_id, args: [:codex_turn_id]
      define :list_turns_in_progress, action: :in_progress_for_project, args: [:project_id]

      define :list_turns_for_thread,
        action: :for_thread,
        args: [:thread_id, {:optional, :include_reverted}]
    end
  end

  alias Longx.Codex.Pool

  require Ash.Query
  alias Longx.Projects.{Thread, Tracker, Turn}

  @doc "Threads of a project, most recently active first."
  def list_threads(%Project{id: id}), do: list_threads_for_project(id)

  def list_threads!(project) do
    {:ok, threads} = list_threads(project)
    threads
  end

  @doc "Turns of a thread, oldest first; reverted ones only with `include_reverted: true`."
  def list_turns(%Thread{id: id}, opts \\ []),
    do: list_turns_for_thread(id, Keyword.get(opts, :include_reverted, false))

  def list_turns!(thread, opts \\ []) do
    {:ok, turns} = list_turns(thread, opts)
    turns
  end

  ## Threads

  @type start_option ::
          {:approval_policy, atom}
          | {:sandbox, atom}
          | {:tools, [String.t()]}
          | {:model, String.t()}
          | {:effort, String.t()}
          | {:network_access, boolean}
          | {:web_search, boolean}
          | {:multi_agent, boolean}
          | {:conn, GenServer.server()}

  @doc """
  Starts a codex thread in the project directory with the project's
  defaults (overridable per call) and records it. The project's model
  (or `model:`) is passed to codex as its slug; nil means the global default.
  `effort:` is the reasoning level to start on (one the model offers;
  default: the model's own), `web_search: false` turns codex's `web.run`
  off for the thread (a thread/start config, so it cannot change later).
  """
  @spec start_thread(Project.t(), [start_option]) :: {:ok, Thread.t()} | {:error, term}
  def start_thread(%Project{} = project, opts \\ []) do
    project = Ash.load!(project, :model)
    model_slug = Keyword.get(opts, :model) || (project.model && project.model.slug)
    # a project that chose nothing gets the globally enabled tools (the memory
    # tools by default) — the tools page is where "none" is decided
    tools =
      case Keyword.get(opts, :tools, project.tools) do
        [] -> Longx.AI.enabled_tool_names()
        chosen -> chosen
      end

    approval_policy = Keyword.get(opts, :approval_policy, project.approval_policy)
    sandbox = Keyword.get(opts, :sandbox, project.sandbox)
    network_access = Keyword.get(opts, :network_access, project.network_access)
    web_search = Keyword.get(opts, :web_search, project.web_search)
    multi_agent = Keyword.get(opts, :multi_agent, project.multi_agent)

    # the model's own settings (context window, reasoning, web search mode);
    # an unknown slug, a missing default or a level the model does not offer
    # is refused before codex is involved
    with {:ok, model_opts} <- Longx.AI.thread_options(model_slug),
         :ok <- Longx.AI.check_effort(model_slug, opts[:effort]),
         model_opts = put_if(model_opts, :reasoning_effort, opts[:effort]),
         {:ok, conn} <- project_connection(project, opts),
         codex_opts =
           [
             cwd: project.root_path,
             approval_policy: approval_policy,
             sandbox: sandbox,
             tools: tools,
             network_access: network_access,
             writable_roots: writable_roots(project),
             multi_agent: multi_agent,
             conn: conn
           ]
           |> Keyword.merge(model_opts)
           |> without_web_search(web_search)
           |> with_global_memory(project),
         {:ok, codex_thread_id} <- Longx.Codex.Thread.start(codex_opts),
         {:ok, thread} <-
           create_thread(%{
             codex_thread_id: codex_thread_id,
             project_id: project.id,
             cwd: project.root_path,
             model_slug: model_slug,
             reasoning_effort: model_opts[:reasoning_effort],
             approval_policy: approval_policy,
             sandbox: sandbox,
             network_access: network_access,
             web_search: web_search,
             multi_agent: multi_agent,
             tools: tools
           }) do
      :ok = Tracker.track(codex_thread_id)
      broadcast_changed(project.id)
      {:ok, thread}
    end
  end

  # what Longx remembers across projects, as the thread's developer instructions
  defp with_global_memory(opts, %Project{global_memory: true}),
    do: Keyword.put(opts, :developer_instructions, Longx.Memory.instructions())

  defp with_global_memory(opts, _project), do: opts

  # the model's mode (thread_options) unless the thread wants no web.run at all
  defp without_web_search(opts, true), do: opts
  defp without_web_search(opts, false), do: Keyword.put(opts, :web_search, :disabled)

  defp put_if(opts, _key, nil), do: opts
  defp put_if(opts, key, value), do: Keyword.put(opts, key, value)

  @doc """
  Sends a user message as a new turn, after the git preflight: on a
  repository with uncommitted changes the project's `dirty_start` policy
  applies (`:commit` commits them first, `:off` only records the fact,
  `:ask` returns `{:error, {:dirty_tree, changes}}` unless `dirty: :commit | :ignore`
  is given). The turn's `commit_before` is HEAD once that is settled.
  Options: `model:` (switches the model from here on), `sandbox:` /
  `approval_policy:` / `network_access:` (the access mode from here on —
  codex keeps a turn's policies for the turns after it; recorded on the
  thread), `conn:`.
  """
  @spec send_message(Thread.t(), String.t(), keyword) ::
          {:ok, Turn.t()} | {:error, {:dirty_tree, [map]} | term}
  def send_message(%Thread{id: id}, text, opts \\ []) do
    # fresh row: the model may have been switched by an earlier turn
    thread = Ash.get!(Thread, id, load: :project)
    model_slug = Keyword.get(opts, :model, thread.model_slug)

    mode = mode_change(thread, opts)

    with :ok <- ensure_usable(thread),
         {:ok, turn_opts} <- turn_options(model_slug, thread),
         :ok <- Longx.AI.check_effort(model_slug, opts[:effort]),
         {turn_opts, effort} = effort_change(turn_opts, thread, opts[:effort]),
         {:ok, conn} <- thread_connection(thread, opts),
         {:ok, bookmark} <- preflight(thread, text, opts),
         {:ok, codex_turn_id} <-
           Longx.Codex.Thread.send(
             thread.codex_thread_id,
             text,
             [{:conn, conn}, {:images, Keyword.get(opts, :images, [])} | turn_opts] ++
               mode_turn_opts(mode, thread)
           ),
         {:ok, turn} <-
           create_turn(%{
             codex_turn_id: codex_turn_id,
             thread_id: thread.id,
             user_text: text,
             model_slug: model_slug,
             reasoning_effort: effort,
             commit_before: bookmark.commit,
             dirty_start: bookmark.dirty?,
             started_at: DateTime.utc_now()
           }) do
      touch_thread!(
        thread,
        Map.merge(mode, %{
          status: :active,
          model_slug: model_slug,
          reasoning_effort: effort,
          last_activity_at: DateTime.utc_now()
        })
      )

      broadcast_changed(thread.project_id)
      {:ok, turn}
    end
  end

  @doc """
  Asks codex to compact the thread's context (the `/compact` command) —
  never while a turn runs, so a compaction cannot land mid-reply.
  """
  @spec compact_thread(Thread.t(), keyword) :: :ok | {:error, :turn_in_progress | term}
  def compact_thread(%Thread{id: id}, opts \\ []) do
    thread = Ash.get!(Thread, id, load: :project)

    with :ok <- ensure_usable(thread),
         :ok <- refuse_while_running(thread),
         {:ok, conn} <- thread_connection(thread, opts),
         do: Longx.Codex.Thread.compact(thread.codex_thread_id, conn: conn)
  end

  @doc """
  Starts codex's code review (the `/review` command) as a turn of the
  thread. Bookmarked like any turn, but nothing is committed first: with
  `dirty_start: :commit` a review of the uncommitted changes would
  otherwise have nothing left to look at.
  """
  @spec review_thread(Thread.t(), Longx.Codex.Thread.review_target(), keyword) ::
          {:ok, Turn.t()} | {:error, term}
  def review_thread(%Thread{id: id}, target, opts \\ []) do
    thread = Ash.get!(Thread, id, load: :project)

    with :ok <- ensure_usable(thread),
         :ok <- refuse_while_running(thread),
         {:ok, conn} <- thread_connection(thread, opts),
         # bookmarked before codex is asked: its first events follow the reply at once
         bookmark = bookmark_now(thread.cwd),
         {:ok, codex_turn_id} <-
           Longx.Codex.Thread.review(thread.codex_thread_id, target, conn: conn),
         {:ok, turn} <-
           create_turn(%{
             codex_turn_id: codex_turn_id,
             thread_id: thread.id,
             user_text: review_text(target),
             model_slug: thread.model_slug,
             commit_before: bookmark.commit,
             dirty_start: bookmark.dirty?,
             started_at: DateTime.utc_now()
           }) do
      touch_thread!(thread, %{status: :active, last_activity_at: DateTime.utc_now()})
      broadcast_changed(thread.project_id)
      {:ok, turn}
    end
  end

  defp review_text(:uncommitted), do: "/review"
  defp review_text({:commit, sha}), do: "/review #{String.slice(sha, 0, 7)}"
  defp review_text({:base_branch, branch}), do: "/review #{branch}"
  defp review_text({:custom, text}), do: "/review #{text}"

  # where the tree stands, without touching it
  defp bookmark_now(dir) do
    if Git.repository?(dir),
      do: %{commit: head_or_nil(dir), dirty?: not Git.status(dir).clean?},
      else: %{commit: nil, dirty?: false}
  end

  # the access-mode fields this call changes (only those that differ)
  defp mode_change(%Thread{} = thread, opts) do
    [:sandbox, :approval_policy, :network_access]
    |> Enum.flat_map(fn key ->
      case Keyword.fetch(opts, key) do
        {:ok, value} when value != nil and value != :erlang.map_get(key, thread) -> [{key, value}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  # turn/start needs the whole sandbox policy when any of it changes
  defp mode_turn_opts(mode, _thread) when map_size(mode) == 0, do: []

  defp mode_turn_opts(mode, %Thread{} = thread) do
    [
      sandbox: Map.get(mode, :sandbox, thread.sandbox),
      approval_policy: Map.get(mode, :approval_policy, thread.approval_policy),
      network_access: Map.get(mode, :network_access, thread.network_access),
      writable_roots: writable_roots(thread.project)
    ]
  end

  @doc """
  What the workspace-write sandbox may write besides the project and /tmp:
  the project's `writable_roots` (`~` = this user's home; only directories
  that exist and are writable — codex seeds every root with protected
  `.git` / `.codex` entries, so a root it cannot write into, or a device
  node, makes bwrap fail to launch).
  """
  @spec writable_roots(Project.t()) :: [Path.t()]
  def writable_roots(%Project{writable_roots: roots}) do
    roots
    |> Enum.map(&Path.expand/1)
    |> Enum.filter(&File.dir?/1)
    |> Enum.uniq()
  end

  @doc """
  Deletes the thread row and its turns (never while a turn runs). Codex's
  own record of the conversation stays in the project's CODEX_HOME —
  `clear_codex_history/1` is the wipe for that.
  """
  @spec delete_thread(Thread.t()) :: :ok | {:error, term}
  def delete_thread(%Thread{} = thread) do
    thread = Ash.get!(Thread, thread.id)

    with :ok <- refuse_while_running(thread) do
      Ash.bulk_destroy!(Ash.Query.filter(Turn, thread_id == ^thread.id), :destroy, %{},
        authorize?: false
      )

      Ash.destroy!(thread)
      broadcast_changed(thread.project_id)
      :ok
    end
  end

  defp refuse_while_running(%Thread{status: :active}), do: {:error, :turn_in_progress}
  defp refuse_while_running(_), do: :ok

  @doc """
  Makes sure some codex hosts the thread with this codex id — what a page
  opening the thread needs before it can subscribe: resumes it on the
  project's codex when nobody hosts it (after a restart), like
  `send_message/3` does lazily. Answers with the codex id to subscribe to:
  an empty thread codex cannot resume (it only writes a thread to disk on
  its first turn) is started again, so the id may be a new one. A thread
  codex can no longer know (`:unrecoverable`, `:archived`) keeps its id:
  nothing to resume, but its last view (if any) may still be shown.
  `{:error, :unknown_thread}` when we never heard of it.
  """
  @spec host_thread(String.t()) :: {:ok, String.t()} | {:error, term}
  def host_thread(codex_thread_id) do
    case get_thread_by_codex_id(codex_thread_id, load: [:project, :turns]) do
      {:ok, %Thread{status: status}} when status in [:unrecoverable, :archived] ->
        {:ok, codex_thread_id}

      {:ok, %Thread{} = thread} ->
        case resume_or_restart(thread) do
          {:ok, %Thread{codex_thread_id: id}} -> {:ok, id}
          {:error, reason} -> {:error, reason}
        end

      {:error, _} ->
        {:error, :unknown_thread}
    end
  end

  defp resume_or_restart(%Thread{turns: []} = thread) do
    case resume_on_pool(thread) do
      {:ok, _conn} -> {:ok, thread}
      {:error, _reason} -> restart_empty_thread(thread)
    end
  end

  defp resume_or_restart(thread) do
    case resume_on_pool(thread) do
      {:ok, _conn} -> {:ok, thread}
      {:error, reason} -> {:error, reason}
    end
  end

  # the same start as start_thread/2, with what the row recorded
  defp restart_empty_thread(%Thread{project: project} = thread) do
    with {:ok, model_opts} <- Longx.AI.thread_options(thread.model_slug),
         {:ok, conn} <- project_connection(project, []),
         codex_opts =
           [
             cwd: thread.cwd,
             approval_policy: thread.approval_policy,
             sandbox: thread.sandbox,
             tools: thread.tools,
             network_access: thread.network_access,
             writable_roots: writable_roots(project),
             multi_agent: thread.multi_agent,
             conn: conn
           ]
           |> Keyword.merge(model_opts)
           |> without_web_search(thread.web_search),
         {:ok, codex_thread_id} <- Longx.Codex.Thread.start(codex_opts) do
      thread = rehost_thread!(thread, %{codex_thread_id: codex_thread_id})
      :ok = Tracker.track(codex_thread_id)
      broadcast_changed(project.id)
      {:ok, thread}
    end
  end

  defp ensure_usable(%Thread{status: :unrecoverable}), do: {:error, :thread_unrecoverable}
  defp ensure_usable(%Thread{status: :archived}), do: {:error, :thread_archived}
  defp ensure_usable(_thread), do: :ok

  ## Which codex

  # `conn:` when the caller has one (tests); else the project's pooled codex
  defp project_connection(%Project{} = project, opts) do
    case Keyword.fetch(opts, :conn) do
      {:ok, conn} -> {:ok, conn}
      :error -> Pool.connection(project.id, shim: shim_options(project))
    end
  end

  defp shim_options(%Project{memory_limit_mb: nil}), do: []
  defp shim_options(%Project{memory_limit_mb: mb}), do: [memory_limit: mb * 1024 * 1024]

  # `conn:` when given; else the codex hosting the thread — after a restart
  # nobody hosts it yet, so it is resumed on the project's codex first
  defp thread_connection(%Thread{} = thread, opts) do
    case Keyword.fetch(opts, :conn) do
      {:ok, conn} -> {:ok, conn}
      :error -> resume_on_pool(thread)
    end
  end

  defp resume_on_pool(%Thread{codex_thread_id: codex_id, project: project} = thread) do
    with {:error, :no_connection} <- Pool.connection_for_thread(codex_id),
         {:ok, conn} <- Pool.connection(project.id, shim: shim_options(project)),
         {:ok, _} <- resume_thread(thread, conn) do
      {:ok, conn}
    end
  end

  @doc """
  `thread/resume` on `conn` with what the model row says *now* (context
  window, reasoning, search mode) and what the thread recorded (network,
  sub-agents) — the same config overrides as its start, so a model edit
  reaches old threads the next time they are resumed.
  """
  @spec resume_thread(Thread.t(), pid) :: {:ok, String.t()} | {:error, term}
  def resume_thread(%Thread{codex_thread_id: codex_id} = thread, conn) do
    project = Ash.get!(Project, thread.project_id)

    with {:ok, model_opts} <- Longx.AI.thread_options(thread.model_slug) do
      opts =
        [
          conn: conn,
          # the access mode the thread is on — codex would resume on its defaults otherwise
          cwd: thread.cwd,
          sandbox: thread.sandbox,
          approval_policy: thread.approval_policy,
          network_access: thread.network_access,
          writable_roots: writable_roots(project),
          multi_agent: thread.multi_agent
        ]
        |> Keyword.merge(model_opts)
        # the level the thread was left on, not the row's default
        |> put_if(:reasoning_effort, thread.reasoning_effort)
        |> without_web_search(thread.web_search)
        |> with_global_memory(project)

      Longx.Codex.Thread.resume(codex_id, opts)
    end
  end

  # The model to name on turn/start (with its reasoning settings): only when
  # this turn switches models — a thread on the default model keeps codex's
  # placeholder, and an unchanged explicit model needs no repeating.
  defp turn_options(nil, _thread), do: {:ok, []}

  defp turn_options(slug, %Thread{model_slug: slug}), do: {:ok, []}

  defp turn_options(slug, _thread), do: Longx.AI.turn_options(slug)

  # The reasoning level this turn runs with, and whether codex must be told:
  # a chosen level replaces whatever `turn_options` proposed (a switched
  # model's default) and is sent when it differs from the thread's; with none
  # chosen the switched model's default (if any) or the thread's level stands.
  # Returns the turn options and the level in force after this turn.
  defp effort_change(turn_opts, %Thread{reasoning_effort: current}, nil) do
    case Keyword.fetch(turn_opts, :effort) do
      {:ok, effort} -> {turn_opts, effort}
      :error -> {turn_opts, current}
    end
  end

  defp effort_change(turn_opts, %Thread{reasoning_effort: current}, effort) do
    if effort == current and not Keyword.has_key?(turn_opts, :model),
      do: {turn_opts, effort},
      else: {Keyword.put(turn_opts, :effort, effort), effort}
  end

  # Where the working tree stands when the turn begins.
  defp preflight(%Thread{cwd: dir, project: project}, text, opts) do
    if Git.repository?(dir) do
      case Git.status(dir) do
        %{clean?: true} ->
          {:ok, %{commit: head_or_nil(dir), dirty?: false}}

        %{changes: changes} ->
          settle_dirty(dir, project.dirty_start, Keyword.get(opts, :dirty), changes, text)
      end
    else
      {:ok, %{commit: nil, dirty?: false}}
    end
  end

  defp settle_dirty(dir, policy, override, changes, text) do
    case override || policy do
      :commit ->
        with {:ok, sha} <-
               Git.commit_all(dir, "longx: before turn — #{String.slice(text, 0, 60)}"),
             do: {:ok, %{commit: sha, dirty?: false}}

      :off ->
        {:ok, %{commit: head_or_nil(dir), dirty?: true}}

      :ignore ->
        {:ok, %{commit: head_or_nil(dir), dirty?: true}}

      :ask ->
        {:error, {:dirty_tree, changes}}
    end
  end

  ## Redoing a turn

  @type redo_option ::
          {:model, String.t()}
          | {:effort, String.t()}
          | {:text, String.t()}
          | {:restore_files, boolean}
          | {:mode, :revert | :fork}
          | {:conn, GenServer.server()}

  @doc """
  Runs turn N again, typically with another model. Steps, each visible in
  git or in the thread:

    1. refuse while a turn is running (`{:error, {:turn_in_progress, id}}`) or
       if this turn was already reverted
    2. `restore_files: true` → `restore_files/2` (safety commit, files back to
       `commit_before`)
    3. `mode: :revert` (default) → `thread/revert` from this turn: it and
       every later turn leave the conversation and the projection, and their
       rows are marked `:reverted`. `mode: :fork` → a new thread holding the
       history *before* this turn (`forked_from`), the original untouched
    4. a new turn with `text:` (default: the original message), `model:`
       (default: the thread's) and `effort:`, through the normal git preflight

  Returns the new turn.
  """
  @spec redo_turn(Turn.t(), [redo_option]) ::
          {:ok, Turn.t()} | {:error, {:turn_in_progress, String.t()} | :turn_reverted | term}
  def redo_turn(%Turn{} = turn, opts \\ []) do
    turn = Ash.get!(Turn, turn.id)
    thread = Ash.get!(Thread, turn.thread_id, load: :project)

    later =
      thread
      |> list_turns!()
      |> Enum.filter(&(DateTime.compare(&1.started_at, turn.started_at) != :lt))

    model = Keyword.get(opts, :model, thread.model_slug)

    with :ok <- ensure_usable(thread),
         {:ok, conn} <- thread_connection(thread, opts),
         :ok <- ensure_redoable(turn, later),
         :ok <- maybe_restore(turn, Keyword.get(opts, :restore_files, false)),
         {:ok, target} <-
           rewind(Keyword.get(opts, :mode, :revert), thread, turn, later, model, conn) do
      send_message(
        target,
        Keyword.get(opts, :text, turn.user_text),
        [model: model] |> put_if(:effort, opts[:effort]) |> put_if(:conn, conn)
      )
    end
  end

  defp ensure_redoable(%Turn{status: :reverted}, _later), do: {:error, :turn_reverted}

  defp ensure_redoable(_turn, later) do
    case Enum.find(later, &(&1.status == :in_progress)) do
      nil -> :ok
      running -> {:error, {:turn_in_progress, running.id}}
    end
  end

  defp maybe_restore(_turn, false), do: :ok

  defp maybe_restore(turn, true) do
    with {:ok, _} <- restore_files(turn, confirm: true), do: :ok
  end

  # revert in place: codex forgets from this turn on; so do we
  defp rewind(:revert, thread, turn, later, _model, conn) do
    turn_ids = Enum.map(later, & &1.codex_turn_id)
    revert_opts = [turn_ids: turn_ids] |> put_if(:conn, conn)

    with :ok <- Longx.Codex.Thread.revert(thread.codex_thread_id, turn.codex_turn_id, revert_opts) do
      Enum.each(later, &mark_turn_reverted!/1)
      {:ok, thread}
    end
  end

  # fork: a sibling thread with the history before this turn
  defp rewind(:fork, thread, turn, _later, model, conn) do
    previous =
      thread
      |> list_turns!()
      |> Enum.filter(&(DateTime.compare(&1.started_at, turn.started_at) == :lt))
      |> List.last()

    with {:ok, model_opts} <- Longx.AI.thread_options(model),
         fork_opts =
           model_opts
           |> put_if(:last_turn_id, previous && previous.codex_turn_id)
           |> put_if(:conn, conn),
         {:ok, codex_thread_id} <- Longx.Codex.Thread.fork(thread.codex_thread_id, fork_opts),
         {:ok, forked} <-
           create_thread(%{
             codex_thread_id: codex_thread_id,
             project_id: thread.project_id,
             cwd: thread.cwd,
             model_slug: model,
             reasoning_effort: model_opts[:reasoning_effort],
             approval_policy: thread.approval_policy,
             sandbox: thread.sandbox,
             tools: thread.tools,
             forked_from_id: thread.id
           }) do
      :ok = Tracker.track(codex_thread_id)
      {:ok, forked}
    end
  end

  ## Restoring

  @doc """
  What `restore_files/2` would do for this turn: the commit it started
  from, whether the tree is dirty now, which files differ, and how many
  later turns exist. The UI shows this and asks for confirmation.
  """
  @spec restore_proposal(Turn.t()) ::
          {:ok,
           %{
             commit: String.t(),
             dirty_now?: boolean,
             changed_files: [String.t()],
             later_turns: non_neg_integer
           }}
          | {:error, :no_git | :no_commit}
  def restore_proposal(%Turn{} = turn) do
    %Turn{thread: %Thread{cwd: dir} = thread} = Ash.load!(turn, :thread)

    with true <- Git.repository?(dir) || {:error, :no_git},
         sha when is_binary(sha) <- turn.commit_before || {:error, :no_commit} do
      later =
        list_turns!(thread)
        |> Enum.filter(&(DateTime.compare(&1.started_at, turn.started_at) == :gt))
        |> length()

      changed = Git.status(dir).changes |> Enum.map(& &1.path)
      changed_vs_commit = Git.diff(dir, sha) |> diff_paths()

      {:ok,
       %{
         commit: sha,
         dirty_now?: changed != [],
         changed_files: Enum.uniq(Enum.sort(changed ++ changed_vs_commit)),
         later_turns: later
       }}
    end
  end

  defp diff_paths(diff) do
    Regex.scan(~r/^diff --git a\/(.+?) b\//m, diff) |> Enum.map(fn [_, path] -> path end)
  end

  @doc """
  Puts the working tree back to how it was before `turn`. Never silent:
  requires `confirm: true`. Uncommitted work is committed first
  (`longx: before restoring to <sha>`) so nothing is lost. `mode:` is
  `:restore_tree` (default — files change, history untouched) or
  `:reset_hard` (the branch itself goes back; the safety commit stays in
  the reflog).
  """
  @spec restore_files(Turn.t(), keyword) ::
          {:ok, %{safety_commit: String.t() | nil, head: String.t()}}
          | {:error, :confirmation_required | :no_git | :no_commit | term}
  def restore_files(%Turn{} = turn, opts \\ []) do
    with true <- Keyword.get(opts, :confirm, false) || {:error, :confirmation_required},
         {:ok, %{commit: sha, dirty_now?: dirty?}} <- restore_proposal(turn) do
      %Turn{thread: %Thread{cwd: dir}} = Ash.load!(turn, :thread)

      with {:ok, safety} <- safety_commit(dir, sha, dirty?),
           :ok <- restore(dir, sha, Keyword.get(opts, :mode, :restore_tree)),
           {:ok, head} <- Git.head(dir) do
        {:ok, %{safety_commit: safety, head: head}}
      end
    end
  end

  defp safety_commit(_dir, _sha, false), do: {:ok, nil}

  defp safety_commit(dir, sha, true),
    do: Git.commit_all(dir, "longx: before restoring to #{String.slice(sha, 0, 8)}")

  defp restore(dir, sha, :restore_tree), do: Git.restore_tree(dir, sha)
  defp restore(dir, sha, :reset_hard), do: Git.reset_hard(dir, sha)

  @doc """
  Deletes the project, its threads and turns, and its `CODEX_HOME` (the
  `delete` action); the working directory is never touched. Needs
  `confirm: true`.
  """
  @spec delete_project(Project.t(), keyword) :: :ok | {:error, term}
  def delete_project(%Project{} = project, opts \\ []) do
    project
    |> Ash.Changeset.for_destroy(:delete, %{confirm: Keyword.get(opts, :confirm, false)})
    |> Ash.destroy()
  end

  ## Change notifications

  @doc "PubSub topic carrying a project's `{:project_changed, id}` and `{:codex_sample, id, m}` messages."
  @spec topic(String.t()) :: String.t()
  def topic(project_id), do: "project:" <> project_id

  @doc "Tells subscribers (the project channel) that thread/turn rows of this project changed."
  @spec broadcast_changed(String.t()) :: :ok
  def broadcast_changed(project_id),
    do: Phoenix.PubSub.broadcast(Longx.PubSub, topic(project_id), {:project_changed, project_id})

  ## The project's codex: process and CODEX_HOME

  # codex's own state inside the home; everything else there is ours (config)
  # what codex keeps in the home besides our config — `memories` (what it
  # learned about the project) is deliberately not history and survives a clear
  @codex_state_globs ~w(*.sqlite *.sqlite-wal *.sqlite-shm sessions logs db-backups archived_sessions skills tmp)

  @doc """
  The project's codex resources: the `CODEX_HOME` directory (path, size,
  the sqlite files codex keeps there) and the worker (`:stopped` or
  `Longx.Codex.Connection.info/1`).
  """
  @spec codex_info(Project.t()) :: %{
          home: Path.t(),
          exists?: boolean,
          bytes: non_neg_integer,
          files: %{String.t() => non_neg_integer},
          worker: :stopped | map,
          stale: [:models | :config]
        }
  def codex_info(%Project{id: project_id}) do
    home = Pool.home_dir(project_id)
    exists? = File.dir?(home)
    worker = Pool.status(project_id)

    files =
      if exists?,
        do:
          home
          |> Path.join("*.sqlite")
          |> Path.wildcard()
          |> Map.new(&{Path.basename(&1), size(&1)}),
        else: %{}

    %{
      home: home,
      exists?: exists?,
      bytes: if(exists?, do: dir_bytes(home), else: 0),
      files: files,
      worker: worker,
      # what the running codex read at boot that has changed since (a
      # model's window, the search mode): it needs a restart to see it
      stale: if(worker == :stopped, do: [], else: Longx.Codex.Home.stale(home))
    }
  end

  @doc """
  Stops the project's codex. Refuses with `{:error, {:turn_in_progress, id}}`
  while a turn runs, unless `force: true` (the turn then fails as "codex
  restarted", see `Longx.Projects.Tracker`).
  """
  @spec stop_codex(Project.t(), keyword) :: :ok | {:error, {:turn_in_progress, String.t()}}
  def stop_codex(%Project{id: project_id}, opts \\ []) do
    running = list_turns_in_progress!(project_id)

    case {running, Keyword.get(opts, :force, false)} do
      {[turn | _], false} -> {:error, {:turn_in_progress, turn.id}}
      _ -> Pool.stop(project_id)
    end
  end

  @doc "Stops (forced) and starts the project's codex again."
  @spec restart_codex(Project.t()) :: {:ok, pid} | {:error, term}
  def restart_codex(%Project{id: project_id} = project),
    do: Pool.restart(project_id, shim: shim_options(project))

  @doc """
  Forgets everything codex knows about this project: stops the worker and
  removes codex's state from the home (sqlite databases, sessions, logs…),
  keeping our config. Our thread and turn rows stay, but the threads become
  `:unrecoverable` — their conversation is gone.
  """
  @spec clear_codex_history(Project.t()) :: :ok
  def clear_codex_history(%Project{id: project_id}) do
    :ok = Pool.stop(project_id)
    home = Pool.home_dir(project_id)

    for glob <- @codex_state_globs,
        path <- Path.wildcard(Path.join(home, glob), match_dot: true) do
      File.rm_rf!(path)
    end

    project_id
    |> list_threads_for_project!()
    |> Enum.each(&touch_thread!(&1, %{status: :unrecoverable}))

    :ok
  end

  @doc """
  Forgets what codex learned about this project — its memories (the
  `memories/` workspace and its state db) — and nothing else: sessions and
  our threads stay. For a project memory that went wrong; the global one
  (`Longx.Memory`) is untouched.
  """
  @spec clear_codex_memories(Project.t()) :: :ok
  def clear_codex_memories(%Project{id: project_id}) do
    :ok = Pool.stop(project_id)
    home = Pool.home_dir(project_id)

    for glob <- ~w(memories memories_*.sqlite memories_*.sqlite-wal memories_*.sqlite-shm),
        path <- Path.wildcard(Path.join(home, glob), match_dot: true) do
      File.rm_rf!(path)
    end

    :ok
  end

  @doc """
  Stops the worker and deletes the whole `CODEX_HOME` (config, sessions,
  memories, everything); the threads become `:unrecoverable`. The next use
  starts codex afresh with a regenerated config.
  """
  @spec reset_codex_home(Project.t()) :: :ok
  def reset_codex_home(%Project{id: project_id}) do
    :ok = Pool.stop(project_id)
    File.rm_rf!(Pool.home_dir(project_id))

    project_id
    |> list_threads_for_project!()
    |> Enum.each(&touch_thread!(&1, %{status: :unrecoverable}))

    broadcast_changed(project_id)
    :ok
  end

  defp size(path), do: File.stat!(path).size

  defp dir_bytes(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&size/1)
    |> Enum.sum()
  end

  @doc "Active projects, newest first; `include_archived: true` for all."
  @spec list_projects(keyword) :: {:ok, [Project.t()]} | {:error, term}
  def list_projects(opts \\ []) do
    if Keyword.get(opts, :include_archived, false),
      do: list_all_projects(),
      else: list_active_projects()
  end

  def list_projects!(opts \\ []) do
    {:ok, projects} = list_projects(opts)
    projects
  end

  ## Files (for the composer's @ mentions)

  @file_matches 20

  @type file_match :: %{
          path: String.t(),
          file_name: String.t(),
          root: String.t(),
          match_type: String.t(),
          score: non_neg_integer,
          indices: [non_neg_integer] | nil
        }

  @doc """
  Fuzzy file matches under the project root, from codex's own file index
  (`fuzzyFileSearch`, the same one its TUI uses for `@`): paths relative to
  the root, best first. An empty query matches nothing.
  """
  @spec search_files(Project.t(), String.t(), keyword) :: {:ok, [file_match]} | {:error, term}
  def search_files(project, query, opts \\ [])

  def search_files(%Project{}, "", _opts), do: {:ok, []}

  def search_files(%Project{root_path: root} = project, query, opts) when is_binary(query) do
    with {:ok, conn} <- project_connection(project, opts),
         {:ok, %{"files" => files}} <-
           Longx.Codex.Connection.request(conn, "fuzzyFileSearch", %{
             "query" => query,
             "roots" => [root]
           }) do
      {:ok,
       files
       |> Enum.reject(&git_internal?(&1["path"]))
       |> Enum.take(@file_matches)
       |> Enum.map(fn f ->
         %{
           path: f["path"],
           file_name: f["file_name"],
           root: f["root"],
           match_type: f["match_type"],
           score: f["score"] || 0,
           indices: f["indices"]
         }
       end)}
    end
  end

  # codex's index includes .git; nobody wants to mention those
  defp git_internal?(path) when is_binary(path),
    do: path == ".git" or String.starts_with?(path, ".git/") or String.contains?(path, "/.git/")

  defp git_internal?(_), do: false

  ## Git

  @type git_info :: %{
          repository?: boolean,
          head: String.t() | nil,
          clean?: boolean | nil,
          changes: non_neg_integer,
          lfs?: boolean
        }

  @doc "Live git state of the project directory — what the UI needs to warn or reassure."
  @spec git_info(Project.t()) :: git_info
  def git_info(%Project{root_path: dir}) do
    case Git.toplevel(dir) do
      {:ok, _top} ->
        %{clean?: clean?, changes: changes} = Git.status(dir)

        %{
          repository?: true,
          head: head_or_nil(dir),
          clean?: clean?,
          changes: length(changes),
          lfs?: Git.lfs?(dir)
        }

      {:error, :not_a_repository} ->
        %{repository?: false, head: nil, clean?: nil, changes: 0, lfs?: false}
    end
  end

  defp head_or_nil(dir) do
    case Git.head(dir) do
      {:ok, sha} -> sha
      {:error, _} -> nil
    end
  end

  @doc """
  Turns a project directory into a git repository: `git init`, a default
  `.gitignore` unless one exists, and a first commit of everything else.
  """
  @spec init_git(Project.t()) :: {:ok, git_info} | {:error, :already_a_repository | term}
  def init_git(%Project{root_path: dir} = project) do
    ignore = Path.join(dir, ".gitignore")

    with false <- Git.repository?(dir),
         :ok <- Git.init(dir),
         :ok <-
           if(File.exists?(ignore), do: :ok, else: File.write(ignore, Longx.Git.Ignore.default())),
         {:ok, _sha} <- Git.commit_all(dir, "Initial commit (Longx)") do
      {:ok, git_info(project)}
    else
      true -> {:error, :already_a_repository}
      {:error, _} = error -> error
    end
  end
end
