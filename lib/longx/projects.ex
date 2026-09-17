defmodule Longx.Projects do
  @moduledoc """
  Projects (working directories with defaults), the agent threads run in
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
      rpc_action :agent_definition, :agent_definition
      rpc_action :promote_local, :promote_local
      rpc_action :init_git, :init_git
    end

    resource Longx.Projects.Thread do
      rpc_action :list_threads, :for_project
      rpc_action :get_thread, :by_id
      rpc_action :list_subagents, :subagents_of
      rpc_action :start_thread, :start_thread
      rpc_action :send_message, :send_message
      rpc_action :interrupt_turn, :interrupt_turn
      rpc_action :steer_turn, :steer_turn
      rpc_action :retract_turn, :retract_turn
      rpc_action :compact_thread, :compact_thread
      rpc_action :answer_request, :answer_request
      rpc_action :list_running_threads, :list_running
      rpc_action :set_goal, :set_goal
      rpc_action :clear_goal, :clear_goal
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
      define :rename_thread, action: :rename
      define :archive_thread, action: :archive
      define :get_thread_by_kernel_id, action: :by_kernel_id, args: [:kernel_thread_id]
      define :list_threads_for_project, action: :for_project, args: [:project_id]
      define :list_threads_with_status, action: :with_status, args: [:project_id, :status]
      define :list_active_threads, action: :active_roots
      define :list_all_active_threads, action: :active
      define :list_subagents, action: :subagents_of, args: [:parent_thread_id]
    end

    resource Longx.Projects.Files
    resource Longx.Projects.Repo

    resource Longx.Projects.Turn do
      define :create_turn, action: :create
      define :complete_turn, action: :complete
      define :set_turn_diff, action: :set_diff
      define :mark_turn_reverted, action: :mark_reverted
      define :get_turn_by_kernel_id, action: :by_kernel_id, args: [:kernel_turn_id]
      define :list_turns_in_progress, action: :in_progress_for_project, args: [:project_id]
      define :list_all_turns_in_progress, action: :in_progress

      define :list_turns_for_thread,
        action: :for_thread,
        args: [:thread_id, {:optional, :include_reverted}]
    end
  end

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
          {:model, String.t()}
          | {:effort, String.t()}
          | {:web_search, boolean}

  @doc """
  Starts a thread in the project directory on the agent kernel
  (`Longx.Agent`) with the project's defaults (overridable per call) and
  records it. The project's model (or `model:`) is the thread's slug; nil
  means the global default. `effort:` is the reasoning level to start on
  (one the model offers; default: the model's own), `web_search: false`
  mounts no search for the thread.
  """
  @spec start_thread(Project.t(), [start_option]) :: {:ok, Thread.t()} | {:error, term}
  def start_thread(%Project{} = project, opts \\ []) do
    project = Ash.load!(project, :model)
    model_slug = Keyword.get(opts, :model) || (project.model && project.model.slug)
    web_search = Keyword.get(opts, :web_search, project.web_search)

    with {:ok, model_opts} <- Longx.AI.thread_options(model_slug),
         :ok <- Longx.AI.check_effort(model_slug, opts[:effort]),
         effort = opts[:effort] || model_opts[:reasoning_effort],
         id = "native_" <> Ash.UUID.generate(),
         {:ok, _pid} <-
           Longx.Agent.ensure(
             thread_id: id,
             project_id: project.id,
             cwd: project.root_path,
             model: model_slug,
             effort: effort,
             web_search: web_search,
             trust: trust_fun(project.id),
             settings: settings_fun(project.id),
             models: &Longx.AI.model_choices/0,
             idle_ms: Longx.Agent.Settings.idle_ms(Longx.Agent.Settings.for_project(project)),
             spawner: &__MODULE__.spawn_native_agent/4
           ),
         {:ok, thread} <-
           create_thread(%{
             kernel_thread_id: id,
             project_id: project.id,
             cwd: project.root_path,
             model_slug: model_slug,
             reasoning_effort: effort,
             web_search: web_search
           }) do
      :ok = Tracker.track(id)
      broadcast_changed(project.id)
      {:ok, thread}
    end
  end

  @doc "Whether the project lets the kernel load its own `.longx/` agent definition."
  @spec trust_local_agent?(String.t()) :: boolean
  def trust_local_agent?(project_id) do
    case Ash.get(Project, project_id) do
      {:ok, %Project{trust_local_agent: trusted}} -> trusted
      _ -> false
    end
  end

  @doc "The kernel's layered agent definition for a project (the settings page)."
  @spec agent_definition(Project.t()) :: map
  def agent_definition(%Project{} = project) do
    loaded =
      Longx.Agent.Loader.load(project.root_path,
        tag: project.id,
        trusted: project.trust_local_agent
      )

    %{
      present: loaded.present?,
      trusted: project.trust_local_agent,
      dir: Path.join(project.root_path, ".longx"),
      model: loaded.model,
      effort: loaded.effort,
      plugs: Enum.map(loaded.plugs, fn {module, _opts} -> plug_label(module) end),
      files: project_files(loaded.layers, project.root_path),
      local_files: local_files(project.root_path),
      agents:
        Enum.map(
          loaded.agents,
          &%{name: &1.name, summary: &1.summary, layer: Atom.to_string(&1.layer)}
        ),
      settings: Longx.Agent.Settings.for_project(project),
      overrides: project.agent_settings || %{},
      errors: Enum.map(loaded.errors, & &1.message)
    }
  end

  # what the local tree holds, relative to it (the candidates for promotion)
  defp local_files(root) do
    local = Path.join(root, ".longx/local")

    if File.dir?(local) do
      local
      |> Path.join("**")
      |> Path.wildcard(match_dot: false)
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.relative_to(&1, local))
      |> Enum.sort()
    else
      []
    end
  end

  # a layer's own module reads as its name in the file, not the namespaced atom
  defp plug_label(module) do
    case module |> Atom.to_string() |> String.replace_prefix("Elixir.", "") do
      "Longx.Agent.Local." <> rest ->
        rest |> String.split(".", parts: 2) |> List.last() |> Kernel.<>(" (.longx)")

      name ->
        name
    end
  end

  defp project_files(layers, root) do
    for %{name: name, files: files} <- layers,
        name in [:project, :local],
        {path, _} <- files,
        do: Path.relative_to(path, root)
  end

  # (re)starts the thread's agent with what the row knows — a sub-agent's row
  # knows its parent and its name (the last segment of its path)
  defp ensure_agent(%Thread{} = thread) do
    Longx.Agent.ensure(
      [
        thread_id: thread.kernel_thread_id,
        project_id: thread.project_id,
        cwd: thread.cwd,
        model: thread.model_slug,
        effort: thread.reasoning_effort,
        web_search: thread.web_search,
        trust: trust_fun(thread.project_id),
        settings: settings_fun(thread.project_id),
        models: &Longx.AI.model_choices/0,
        idle_ms:
          Longx.Agent.Settings.idle_ms(Longx.Agent.Settings.for_project_id(thread.project_id)),
        spawner: &__MODULE__.spawn_native_agent/4
      ] ++ team_opts(thread)
    )
  end

  # read at every turn, like the trust switch
  defp settings_fun(project_id), do: fn -> Longx.Agent.Settings.for_project_id(project_id) end

  # read at every turn: the switch in the settings applies without a restart
  defp trust_fun(project_id), do: fn -> trust_local_agent?(project_id) end

  @doc """
  The person's answer to a request on the thread: a tool's ask
  (`Longx.Agent.Context.ask/2`) or a plug's question, by request id.
  """
  @spec answer_request(Thread.t(), String.t(), map) :: :ok | {:error, term}
  def answer_request(%Thread{} = thread, request_id, answers) when is_map(answers),
    do: Longx.Agent.respond(thread.kernel_thread_id, request_id, answers)

  @doc """
  Moves a file of the project's `.longx/local/` tree (`"plugs/x.exs"`,
  `"agents/helper/agent.exs"`, `"knowledge/deploy/steps.md"`) into
  `.longx/shared/` — reviewed, for the team. `{:ok, "shared/…"}`.
  """
  @spec promote_local(Project.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def promote_local(%Project{root_path: root}, rel) do
    with {:ok, _to} <- Longx.Agent.Layout.promote(root, rel) do
      {:ok, Path.join("shared", rel)}
    end
  end

  defp team_opts(%Thread{parent_thread_id: nil}), do: []

  defp team_opts(%Thread{parent_thread_id: parent_id, agent_path: path}) do
    case Ash.get(Thread, parent_id) do
      {:ok, %Thread{kernel_thread_id: parent}} ->
        name = (path || "") |> String.split("/") |> List.last()
        [parent: parent, name: name, role: role_of(name), depth: depth_of(path), path: path]

      _ ->
        []
    end
  end

  # "researcher-2" runs the researcher role; the depth is the path's
  defp role_of(name), do: Regex.replace(~r/-\d+$/, name, "")
  defp depth_of(path), do: Kernel.max(length(String.split(path || "", "/", trim: true)) - 1, 0)

  # how the kernel starts a child: a row under the parent, its agent, and the
  # task as its first turn — the child's report is a message in the parent's
  # mailbox
  @doc false
  @spec spawn_native_agent(map, String.t(), String.t(), keyword) ::
          {:ok, String.t()} | {:error, term}
  def spawn_native_agent(parent_state, name, task, opts) do
    child_id = "native_" <> Ash.UUID.generate()
    turn_id = "turn_" <> Ash.UUID.generate()

    with {:ok, %Thread{} = parent} <- get_thread_by_kernel_id(parent_state.thread_id),
         # no model given: the role's own, else the default — not the parent's
         model_slug = Keyword.get(opts, :model),
         effort = Keyword.get(opts, :effort),
         {:ok, child} <-
           create_thread(%{
             kernel_thread_id: child_id,
             project_id: parent.project_id,
             parent_thread_id: parent.id,
             agent_path: (parent.agent_path || "/root") <> "/" <> name,
             title: name,
             cwd: Keyword.get(opts, :cwd, parent.cwd),
             model_slug: model_slug,
             reasoning_effort: effort,
             web_search: parent.web_search,
             status: :active
           }),
         {:ok, _pid} <- ensure_agent(child),
         :ok <- Tracker.track(child_id),
         {:ok, _turn} <-
           create_turn(%{
             kernel_turn_id: turn_id,
             thread_id: child.id,
             user_text: String.slice(task, 0, 200),
             model_slug: model_slug,
             reasoning_effort: effort,
             commit_before: head_or_nil(child.cwd),
             dirty_start: false,
             started_at: DateTime.utc_now()
           }),
         {:ok, %{steered: false}} <- Longx.Agent.send(child_id, task, turn_id: turn_id) do
      broadcast_changed(parent.project_id)
      {:ok, child_id}
    end
  end

  defp put_if(opts, _key, nil), do: opts
  defp put_if(opts, key, value), do: Keyword.put(opts, key, value)

  @doc """
  Sends a user message as a new turn, after the git preflight: on a
  repository with uncommitted changes the project's `dirty_start` policy
  applies (`:commit` commits them first, `:off` only records the fact,
  `:ask` returns `{:error, {:dirty_tree, changes}}` unless `dirty: :commit | :ignore`
  is given). The turn's `commit_before` is HEAD once that is settled.
  Options: `model:` (switches the model from here on), `effort:` (the
  level from here on), `images:` (data urls). `{:error, :turn_in_progress}`
  while a turn runs — a message then is a steer (`steer_message/3`).
  """
  @spec send_message(Thread.t(), String.t(), keyword) ::
          {:ok, Turn.t()} | {:error, {:dirty_tree, [map]} | :turn_in_progress | term}
  def send_message(%Thread{id: id}, text, opts \\ []) do
    # fresh row: the model may have been switched by an earlier turn
    thread = Ash.get!(Thread, id, load: :project)
    model_slug = Keyword.get(opts, :model, thread.model_slug)
    effort = opts[:effort] || thread.reasoning_effort

    # the row first (so the Tracker finds it when the first event lands),
    # then the message
    with :ok <- ensure_usable(thread),
         :ok <- refuse_while_running(thread),
         {:ok, _} <- Longx.AI.thread_options(model_slug),
         :ok <- Longx.AI.check_effort(model_slug, opts[:effort]),
         {:ok, _pid} <- ensure_agent(thread),
         :ok <- Tracker.track(thread.kernel_thread_id),
         {:ok, bookmark} <- preflight(thread, text, opts),
         turn_id = "turn_" <> Ash.UUID.generate(),
         {:ok, turn} <-
           create_turn(%{
             kernel_turn_id: turn_id,
             thread_id: thread.id,
             user_text: text,
             model_slug: model_slug,
             reasoning_effort: effort,
             commit_before: bookmark.commit,
             dirty_start: bookmark.dirty?,
             started_at: DateTime.utc_now()
           }),
         {:ok, %{steered: false}} <-
           Longx.Agent.send(
             thread.kernel_thread_id,
             text,
             [turn_id: turn_id, images: Keyword.get(opts, :images, [])]
             |> put_if(:model, model_slug)
             |> put_if(:effort, effort)
           ) do
      touch_thread!(thread, %{
        status: :active,
        model_slug: model_slug,
        reasoning_effort: effort,
        last_activity_at: DateTime.utc_now()
      })

      broadcast_changed(thread.project_id)
      {:ok, turn}
    else
      {:ok, %{steered: true}} -> {:error, :turn_in_progress}
      other -> other
    end
  end

  @doc """
  Folds the thread's context (the `/compact` command): at once when the
  agent is idle, before its next step while a turn runs.
  """
  @spec compact_thread(Thread.t()) :: :ok | {:error, term}
  def compact_thread(%Thread{id: id}) do
    thread = Ash.get!(Thread, id, load: :project)

    with :ok <- ensure_usable(thread),
         {:ok, _} <- ensure_agent(thread),
         do: Longx.Agent.compact(thread.kernel_thread_id)
  end

  @doc """
  Every root thread with a turn in flight, across projects, newest activity
  first — the welcome page's way back into what is running. `waiting` is
  whether the thread holds a question for the person.
  """
  @spec running_threads() :: [map]
  def running_threads do
    list_active_threads!(load: :project)
    |> Enum.map(fn %Thread{} = thread ->
      %{
        id: thread.id,
        kernel_thread_id: thread.kernel_thread_id,
        title: thread.title,
        preview: thread.preview,
        last_activity_at: thread.last_activity_at,
        project_id: thread.project_id,
        project_slug: thread.project.slug,
        project_name: thread.project.name,
        waiting: Longx.Agent.ThreadState.Store.requests(thread.kernel_thread_id) != []
      }
    end)
  end

  ## The notify feed

  @doc """
  Pushes a `Longx.Notify` event about a thread: the page it points at is
  the root thread's (a sub-agent's row answers through its parent), the
  body what happened. `kind` and `title`/`body` are the caller's.
  """
  @spec notify(Thread.t(), String.t(), keyword) :: :ok
  def notify(%Thread{} = thread, kind, opts) do
    thread = Ash.get!(Thread, thread.id, load: :project)
    root_id = thread.parent_thread_id || thread.id

    Longx.Notify.push(%{
      kind: kind,
      title: Keyword.fetch!(opts, :title),
      body: Keyword.get(opts, :body) || thread_label(thread),
      url: "/p/#{thread.project.slug}/t/#{root_id}",
      project_id: thread.project_id,
      thread_id: root_id
    })
  end

  @doc "How a thread is named to the person: its title, else its first message, else the project."
  @spec thread_label(Thread.t()) :: String.t()
  def thread_label(%Thread{title: title}) when is_binary(title) and title != "", do: title

  def thread_label(%Thread{preview: preview}) when is_binary(preview) and preview != "",
    do: preview

  def thread_label(%Thread{project: %Project{name: name}}), do: name
  def thread_label(%Thread{}), do: "会话"

  ## Goals

  @doc """
  Sets or changes the thread's goal (`Longx.Agent.set_goal/2`): `objective`,
  `status` (`:active` | `:paused` | `:complete` …), `token_budget` (nil =
  none). While a goal is active the agent starts the next turn by itself
  whenever it goes idle — the Tracker records those turns like any other
  (`record_external_turn/2`).
  """
  @spec set_goal(Thread.t(), map) :: {:ok, map} | {:error, term}
  def set_goal(%Thread{} = thread, attrs) do
    thread = Ash.get!(Thread, thread.id, load: :project)

    with :ok <- ensure_usable(thread),
         {:ok, _pid} <- ensure_agent(thread),
         :ok <- Tracker.track(thread.kernel_thread_id) do
      Longx.Agent.set_goal(thread.kernel_thread_id, goal_attrs(attrs))
    end
  end

  # the kernel keeps the wire shape (camelCase, status as a string)
  defp goal_attrs(attrs) do
    attrs
    |> Enum.flat_map(fn
      {:objective, v} -> [{"objective", v}]
      {:status, v} when not is_nil(v) -> [{"status", to_string(v)}]
      {:token_budget, v} -> [{"tokenBudget", v}]
      _ -> []
    end)
    |> Map.new()
  end

  @doc "Drops the thread's goal; whether there was one."
  @spec clear_goal(Thread.t()) :: {:ok, boolean} | {:error, term}
  def clear_goal(%Thread{} = thread) do
    thread = Ash.get!(Thread, thread.id, load: :project)

    with {:ok, _pid} <- ensure_agent(thread),
         do: Longx.Agent.clear_goal(thread.kernel_thread_id)
  end

  @doc """
  A turn the agent started by itself (a goal's continuation, a child's
  report waking its parent): a Turn row bookmarked like one the person sent
  — HEAD at the start, whether the tree was dirty (no commit is made for
  it: nobody chose) — so the history, the restore points and the welcome
  page see it.
  """
  @spec record_external_turn(Thread.t(), String.t()) :: {:ok, Turn.t()} | {:error, term}
  def record_external_turn(%Thread{} = thread, kernel_turn_id) do
    goal = Longx.Agent.ThreadState.Store.meta(thread.kernel_thread_id).goal

    text =
      case goal do
        %{"objective" => objective} when is_binary(objective) -> "（目标续跑）" <> objective
        _ -> "（agent 消息）"
      end

    bookmark =
      if Git.repository?(thread.cwd) do
        %{commit: head_or_nil(thread.cwd), dirty?: not Git.status(thread.cwd).clean?}
      else
        %{commit: nil, dirty?: false}
      end

    with {:ok, turn} <-
           create_turn(%{
             kernel_turn_id: kernel_turn_id,
             thread_id: thread.id,
             user_text: String.slice(text, 0, 200),
             model_slug: thread.model_slug,
             reasoning_effort: thread.reasoning_effort,
             commit_before: bookmark.commit,
             dirty_start: bookmark.dirty?,
             started_at: DateTime.utc_now()
           }) do
      touch_thread!(thread, %{status: :active, last_activity_at: DateTime.utc_now()})
      broadcast_changed(thread.project_id)
      {:ok, turn}
    end
  end

  @doc """
  What a previous boot left running: no agent survives the BEAM, so every
  `:in_progress` turn failed and every `:active` thread is idle. Run once at
  start (`Longx.Application`), before anything can start a new turn.
  """
  @spec settle_after_restart() :: %{turns: non_neg_integer, threads: non_neg_integer}
  def settle_after_restart do
    turns = list_all_turns_in_progress!()

    for turn <- turns do
      complete_turn!(turn, %{
        status: :failed,
        completed_at: DateTime.utc_now(),
        error: "Longx restarted while this turn was running"
      })
    end

    threads = list_all_active_threads!()
    for thread <- threads, do: touch_thread!(thread, %{status: :idle})

    for project_id <- Enum.uniq(Enum.map(threads, & &1.project_id)),
        do: broadcast_changed(project_id)

    %{turns: length(turns), threads: length(threads)}
  end

  @doc "Files changed under the project: the UI refetches the tree and git."
  @spec broadcast_files_changed(String.t(), [String.t()]) :: :ok
  def broadcast_files_changed(project_id, paths),
    do:
      Phoenix.PubSub.broadcast(
        Longx.PubSub,
        topic(project_id),
        {:files_changed, project_id, paths}
      )

  @doc """
  Stops a running turn that has produced nothing yet and takes it out of
  the history — what a stop right after sending means: the message comes
  back to be edited (`text`), not left in the conversation twice. The turn
  is interrupted, truncated from the transcript and the row marked
  `:reverted`. `{:error, :has_output}` once the model ran anything
  (interrupt it instead), `{:error, :not_running}` when it is over.
  Thinking and a half-said answer do not count as output — nothing happened
  that a revert cannot take back.
  """
  @spec retract_turn(Thread.t(), Turn.t()) ::
          {:ok, %{text: String.t()}} | {:error, :has_output | :not_running | term}
  def retract_turn(%Thread{} = thread, %Turn{} = turn) do
    thread = Ash.get!(Thread, thread.id, load: :project)
    turn = Ash.get!(Turn, turn.id)
    kernel_id = thread.kernel_thread_id

    with :ok <- retractable(turn, Longx.Agent.ThreadState.snapshot(kernel_id)) do
      # marked before the interrupt: the Tracker's turn/completed (after a git
      # call) would otherwise land on the row after us and make it interrupted
      mark_turn_reverted!(turn)

      case Longx.Agent.retract(kernel_id, turn.kernel_turn_id) do
        :ok ->
          touch_thread!(thread, %{status: :idle, last_activity_at: DateTime.utc_now()})
          broadcast_changed(thread.project_id)
          {:ok, %{text: turn.user_text || ""}}

        {:error, reason} ->
          complete_turn!(turn, %{status: :in_progress})
          {:error, reason}
      end
    end
  end

  @doc """
  A message while a turn runs goes *into* that turn: the agent hands it to
  the model at its next step and shows it as a user message on the running
  turn — no new Turn row. `{:error, :not_running}` when nothing runs (send
  it as a turn instead).
  """
  @spec steer_message(Thread.t(), String.t(), keyword) ::
          {:ok, %{kernel_turn_id: String.t()}} | {:error, :not_running | term}
  def steer_message(%Thread{} = thread, text, opts \\ []) when is_binary(text) do
    thread = Ash.get!(Thread, thread.id, load: :project)
    id = thread.kernel_thread_id

    with {:running, _} <- agent_status(id),
         {:ok, %{turn_id: turn_id, steered: true}} <-
           Longx.Agent.send(id, text, images: Keyword.get(opts, :images, [])) do
      touch_thread!(thread, %{last_activity_at: DateTime.utc_now()})
      {:ok, %{kernel_turn_id: turn_id}}
    else
      :idle -> {:error, :not_running}
      {:ok, %{steered: false}} -> {:error, :not_running}
    end
  end

  defp agent_status(id) do
    case Longx.Agent.whereis(id) do
      nil -> :idle
      _pid -> Longx.Agent.status(id)
    end
  end

  @doc """
  Stops the turn in flight (the composer's stop button; the Tracker's
  stall watchdog). `{:error, :not_running}` when that turn is not the one
  running.
  """
  @spec interrupt_turn(Thread.t(), String.t()) :: :ok | {:error, :not_running}
  def interrupt_turn(%Thread{} = thread, kernel_turn_id) do
    case agent_status(thread.kernel_thread_id) do
      {:running, ^kernel_turn_id} -> Longx.Agent.interrupt(thread.kernel_thread_id)
      _ -> {:error, :not_running}
    end
  end

  # Words are no side effect: thinking and a half-said answer are dropped with
  # the turn. Anything that runs — a command, a patch, a tool, a search, a
  # sub-agent — or waits to (a question) leaves traces a revert cannot undo,
  # so that turn is only interrupted.
  @harmless_items ~w(userMessage agentMessage reasoning plan)

  defp retractable(%Turn{status: status}, _snapshot) when status != :in_progress,
    do: {:error, :not_running}

  defp retractable(%Turn{kernel_turn_id: turn_id}, %{items: items, pending_requests: requests}) do
    ran? = Enum.any?(items, &(&1["turnId"] == turn_id and &1["type"] not in @harmless_items))
    asked? = Enum.any?(requests, &(&1.params["turnId"] == turn_id))
    if ran? or asked?, do: {:error, :has_output}, else: :ok
  end

  @doc """
  Deletes the thread row, its turns, its agent and its transcript (never
  while a turn runs).
  """
  @spec delete_thread(Thread.t()) :: :ok | {:error, term}
  def delete_thread(%Thread{} = thread) do
    thread = Ash.get!(Thread, thread.id)

    with :ok <- refuse_while_running(thread) do
      Ash.bulk_destroy!(Ash.Query.filter(Turn, thread_id == ^thread.id), :destroy, %{},
        authorize?: false
      )

      Longx.Agent.stop(thread.kernel_thread_id)
      Longx.Agent.Transcript.delete!(thread.kernel_thread_id)

      Ash.destroy!(thread)
      broadcast_changed(thread.project_id)
      :ok
    end
  end

  defp refuse_while_running(%Thread{status: :active}), do: {:error, :turn_in_progress}
  defp refuse_while_running(_), do: :ok

  @doc """
  Makes sure the thread's agent runs — what a page opening the thread needs
  before it can subscribe: after a restart the agent is started again from
  the row and its transcript. Answers with the kernel id to subscribe to. A
  thread that can no longer run (`:unrecoverable`, `:archived`) keeps its
  id: nothing to start, but its last view (if any) may still be shown.
  `{:error, :unknown_thread}` when we never heard of it.
  """
  @spec host_thread(String.t()) :: {:ok, String.t()} | {:error, term}
  def host_thread(kernel_thread_id) do
    case get_thread_by_kernel_id(kernel_thread_id, load: [:project]) do
      {:ok, %Thread{status: status}} when status in [:unrecoverable, :archived] ->
        {:ok, kernel_thread_id}

      {:ok, %Thread{kernel_thread_id: id} = thread} ->
        with {:ok, _pid} <- ensure_agent(thread), :ok <- Tracker.track(id), do: {:ok, id}

      {:error, _} ->
        {:error, :unknown_thread}
    end
  end

  defp ensure_usable(%Thread{status: :unrecoverable}), do: {:error, :thread_unrecoverable}
  defp ensure_usable(%Thread{status: :archived}), do: {:error, :thread_archived}
  defp ensure_usable(_thread), do: :ok

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
  Deletes the project, its threads, turns, transcripts and attachments (the
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

  @doc "PubSub topic carrying a project's `{:project_changed, id}` and `{:files_changed, id, paths}` messages."
  @spec topic(String.t()) :: String.t()
  def topic(project_id), do: "project:" <> project_id

  @doc "Tells subscribers (the project channel) that thread/turn rows of this project changed."
  @spec broadcast_changed(String.t()) :: :ok
  def broadcast_changed(project_id),
    do: Phoenix.PubSub.broadcast(Longx.PubSub, topic(project_id), {:project_changed, project_id})

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
  @file_walk_cap 20_000
  @skipped_dirs [".git", "node_modules", "_build", "deps"]

  @type file_match :: %{
          path: String.t(),
          file_name: String.t(),
          root: String.t(),
          match_type: String.t(),
          score: non_neg_integer,
          indices: [non_neg_integer] | nil
        }

  @doc """
  Fuzzy file matches under the project root: a walk of the tree (`.git`
  and build trees skipped), the query's characters matched in order (a
  subsequence), shortest paths first; paths relative to the root. An empty
  query matches nothing.
  """
  @spec search_files(Project.t(), String.t()) :: {:ok, [file_match]}
  def search_files(%Project{}, ""), do: {:ok, []}

  def search_files(%Project{root_path: root}, query) when is_binary(query) do
    needle = String.downcase(query)

    matches =
      root
      |> walk_files(@file_walk_cap)
      |> Enum.filter(&subsequence?(String.downcase(&1), needle))
      |> Enum.sort_by(&{String.length(&1), &1})
      |> Enum.take(@file_matches)
      |> Enum.map(fn path ->
        %{
          path: path,
          file_name: Path.basename(path),
          root: root,
          match_type: "fuzzy",
          score: 0,
          indices: nil
        }
      end)

    {:ok, matches}
  end

  # relative paths of the files under `root`, at most `cap`
  defp walk_files(root, cap), do: root |> walk_dirs([""], [], cap) |> Enum.reverse()

  defp walk_dirs(_root, [], acc, _cap), do: acc

  defp walk_dirs(root, [dir | rest], acc, cap) when length(acc) < cap do
    entries =
      case File.ls(Path.join(root, dir)) do
        {:ok, names} -> Enum.sort(names)
        {:error, _} -> []
      end

    {dirs, files} =
      entries
      |> Enum.reject(&(&1 in @skipped_dirs))
      |> Enum.map(&String.trim_leading(Path.join(dir, &1), "/"))
      |> Enum.split_with(&File.dir?(Path.join(root, &1)))

    walk_dirs(root, dirs ++ rest, Enum.reduce(files, acc, &[&1 | &2]), cap)
  end

  defp walk_dirs(_root, _dirs, acc, _cap), do: acc

  defp subsequence?(_haystack, ""), do: true

  defp subsequence?(haystack, needle) do
    needle
    |> String.graphemes()
    |> Enum.reduce_while(haystack, fn ch, rest ->
      case String.split(rest, ch, parts: 2) do
        [_, after_match] -> {:cont, after_match}
        [_] -> {:halt, nil}
      end
    end) != nil
  end

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
  `{:error, :no_git}` on a machine without git.
  """
  @spec init_git(Project.t()) ::
          {:ok, git_info} | {:error, :already_a_repository | :no_git | term}
  def init_git(%Project{root_path: dir} = project) do
    ignore = Path.join(dir, ".gitignore")

    with true <- Git.available?() || {:error, :no_git},
         false <- Git.repository?(dir),
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
