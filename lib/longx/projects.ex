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
      rpc_action :set_thread_handle, :set_handle_action
      rpc_action :set_thread_on_duty, :set_on_duty_action
      rpc_action :directory, :directory
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
      define :set_thread_handle, action: :set_handle
      define :set_thread_on_duty, action: :set_on_duty
      define :get_thread_by_handle, action: :by_handle, args: [:project_id, :handle]
      define :archive_thread, action: :archive
      define :get_thread_by_kernel_id, action: :by_kernel_id, args: [:kernel_thread_id]
      define :list_threads_for_project, action: :for_project, args: [:project_id]
      define :list_threads_with_status, action: :with_status, args: [:project_id, :status]
      define :list_active_threads, action: :active_roots
      define :list_all_root_threads, action: :roots
      define :list_all_active_threads, action: :active
      define :list_subagents, action: :subagents_of, args: [:parent_thread_id]
    end

    resource Longx.Projects.Files
    resource Longx.Projects.Repo

    resource Longx.Projects.Turn do
      define :create_turn, action: :create
      define :complete_turn, action: :complete
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
          | {:handle, String.t()}
          | {:title, String.t()}

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
             idle_ms:
               Longx.Agent.Definition.Settings.idle_ms(
                 Longx.Agent.Definition.Settings.for_project(project)
               ),
             spawner: &__MODULE__.spawn_native_agent/4
           ),
         {:ok, thread} <-
           create_thread(%{
             kernel_thread_id: id,
             project_id: project.id,
             cwd: project.root_path,
             model_slug: model_slug,
             reasoning_effort: effort,
             web_search: web_search,
             handle: opts[:handle],
             title: opts[:title]
           }) do
      :ok = Tracker.track(id)
      broadcast_changed(project.id)
      {:ok, thread}
    end
  end

  ## The directory: who is here, how to reach them

  @doc "Gives the session its handle (a slug, unique in the project); nil takes it away."
  @spec set_handle(Thread.t(), String.t() | nil) :: {:ok, Thread.t()} | {:error, term}
  def set_handle(%Thread{} = thread, handle) do
    with {:ok, thread} <- set_thread_handle(thread, %{handle: handle}) do
      broadcast_changed(thread.project_id)
      {:ok, thread}
    end
  end

  @doc """
  Puts a session on duty — another agent may wake it with a message — or
  takes it off. A conversation the person had and left is off duty by
  default: an agent once woke one to ask about files it had seen, and the
  person had not meant that session to work any more.
  """
  @spec set_on_duty(Thread.t(), boolean) :: {:ok, Thread.t()} | {:error, term}
  def set_on_duty(%Thread{} = thread, on_duty) when is_boolean(on_duty) do
    with {:ok, thread} <- set_thread_on_duty(thread, %{on_duty: on_duty}) do
      broadcast_changed(thread.project_id)
      {:ok, thread}
    end
  end

  @doc """
  Whether other agents may wake this session: the switch, a handle (the
  person or the agent named it to be found — a watch's session too), or an
  active goal (it is at work on something).
  """
  @spec on_duty?(Thread.t()) :: boolean
  def on_duty?(%Thread{on_duty: true}), do: true
  def on_duty?(%Thread{handle: handle}) when is_binary(handle) and handle != "", do: true

  def on_duty?(%Thread{kernel_thread_id: id}),
    do: match?(%{status: "active"}, goal_summary(id))

  @doc """
  How other agents call this session: its handle, else its team name (a
  sub-agent's), else `~` and the last six characters of its id — every
  session has an address, named or not.
  """
  @spec agent_name(Thread.t()) :: String.t()
  def agent_name(%Thread{handle: handle}) when is_binary(handle) and handle != "", do: handle

  def agent_name(%Thread{agent_path: path}) when is_binary(path) and path != "/root",
    do: path |> String.split("/", trim: true) |> List.last()

  def agent_name(%Thread{id: id}), do: "~" <> String.slice(id, -6, 6)

  @doc """
  The sessions of the project (its root threads, not archived) as one table
  an agent or the page reads: `address`, `handle`, `title`, `preview`,
  `state` (`:running` a turn in flight | `:waiting` an ask open | `:idle` the
  process up | `:asleep` the process left, the row stays), `goal`, `team`
  (its sub-agents' names), `last_activity_at`. `scope: :all` lists every
  project, the address prefixed `<project slug>:`.
  """
  @spec directory(String.t(), keyword) :: [map]
  def directory(project_id, opts \\ []) do
    threads =
      case Keyword.get(opts, :scope, :project) do
        :all -> list_all_root_threads!(load: :project)
        _ -> list_threads_for_project!(project_id)
      end

    for %Thread{} = thread <- threads do
      name = agent_name(thread)
      other? = thread.project_id != project_id
      team = list_subagents!(thread.id)
      # a session whose agent works for it is busy, idle itself or not
      state =
        case session_state(thread) do
          idle when idle in [:idle, :asleep] ->
            if Enum.any?(team, &(&1.status == :active)), do: :running, else: idle

          state ->
            state
        end

      %{
        thread_id: thread.id,
        kernel_thread_id: thread.kernel_thread_id,
        project_id: thread.project_id,
        project_slug: other? && thread.project.slug,
        address: if(other?, do: thread.project.slug <> ":" <> name, else: name),
        handle: thread.handle,
        title: thread.title,
        preview: thread.preview,
        state: state,
        goal: goal_summary(thread.kernel_thread_id),
        on_duty: on_duty?(thread),
        team: Enum.map(team, &agent_name/1),
        last_activity_at: thread.last_activity_at
      }
    end
  end

  defp session_state(%Thread{status: :archived}), do: :archived
  defp session_state(%Thread{status: :unrecoverable}), do: :unrecoverable

  # read off ETS and the registry only: the directory is built inside agent
  # processes (the Agents plug's prompt), and a call to one would be a call to itself
  defp session_state(%Thread{kernel_thread_id: id}) do
    cond do
      Longx.Agent.ThreadState.Store.requests(id) != [] -> :waiting
      Longx.Agent.whereis(id) == nil -> :asleep
      match?(%{"status" => "inProgress"}, Longx.Agent.ThreadState.Store.meta(id).turn) -> :running
      true -> :idle
    end
  end

  defp goal_summary(kernel_thread_id) do
    case Longx.Agent.ThreadState.Store.meta(kernel_thread_id).goal do
      %{"objective" => objective} = goal -> %{objective: objective, status: goal["status"]}
      _ -> nil
    end
  end

  @doc """
  The session an address names, inside `project_id`: a handle, `~<id
  suffix>`, or `<project slug>:<handle>` for another project's. Archived
  sessions are not found.
  """
  @spec resolve_address(String.t(), String.t()) :: {:ok, Thread.t()} | {:error, :not_found}
  def resolve_address(project_id, address) when is_binary(address) do
    found =
      case String.split(address, ":", parts: 2) do
        [slug, name] ->
          case get_project_by_slug(slug) do
            {:ok, %Project{id: id}} -> find_session(id, name)
            _ -> nil
          end

        [name] ->
          find_session(project_id, name)
      end

    case found do
      %Thread{status: status} = thread when status not in [:archived] -> {:ok, thread}
      _ -> {:error, :not_found}
    end
  end

  defp find_session(project_id, "~" <> suffix) do
    project_id
    |> list_threads_for_project!()
    |> Enum.find(&String.ends_with?(&1.id, suffix))
  end

  defp find_session(project_id, handle) do
    case get_thread_by_handle(project_id, handle) do
      {:ok, thread} -> thread
      _ -> nil
    end
  end

  @doc """
  A message from one session (or a watch) to another, by address: the
  target is brought up if it left, tracked, and `Longx.Agent.send/3` puts
  the text in its mailbox — a steer while it runs (`deliver: :now`, the
  default) or a turn of its own once idle (`deliver: :idle`). `from_thread:`
  is the sender's kernel id: the message is signed with its name and the
  target's answer comes back to it (signed with the target's address);
  `from:` names a sender that is no session (a watch). `{:error, :self}`
  to oneself, `{:error, :not_found}` for an address nobody has,
  `{:error, :off_duty}` for a session that is not on duty (`on_duty?/1`) —
  the person's conversations are not woken by agents or watches.
  """
  @spec deliver(String.t(), String.t(), String.t(), keyword) ::
          {:ok, Thread.t()} | {:error, :self | :not_found | :off_duty | term}
  def deliver(project_id, address, text, opts) when is_binary(text) do
    with {:ok, %Thread{} = target} <- resolve_address(project_id, address),
         :ok <- not_self(target, opts[:from_thread]),
         :ok <- ensure_usable(target),
         :ok <- ensure_on_duty(target),
         {:ok, send_opts} <- delivery_opts(target, opts),
         :ok <- wake(target),
         {:ok, _} <- sent(Longx.Agent.send(target.kernel_thread_id, text, send_opts)) do
      {:ok, target}
    end
  end

  defp not_self(%Thread{kernel_thread_id: id}, id), do: {:error, :self}
  defp not_self(_target, _from), do: :ok

  defp ensure_on_duty(target), do: if(on_duty?(target), do: :ok, else: {:error, :off_duty})

  defp delivery_opts(target, opts) do
    base = [deliver: Keyword.get(opts, :deliver, :now), hops: Keyword.get(opts, :hops, 0)]

    case Keyword.get(opts, :from_thread) do
      nil ->
        {:ok, [from: Keyword.get(opts, :from, "someone")] ++ base}

      sender_id ->
        with {:ok, sender} <- get_thread_by_kernel_id(sender_id) do
          {:ok,
           [from: agent_name(sender), reply_to: sender_id, reply_as: agent_name(target)] ++ base}
        end
    end
  end

  defp sent(:ok), do: {:ok, :postponed}
  defp sent(other), do: other

  # the agent up (from its spec or its row), the view's turns seeded, the Tracker on it
  defp wake(%Thread{kernel_thread_id: id} = thread) do
    with {:ok, _pid} <- ensure_agent(thread),
         :ok <- seed_turns(thread),
         do: Tracker.track(id)
  end

  @doc """
  The session with that handle, started with `title:` (and the project's
  defaults) when there is none — a watch's own session, a role's standing
  one.
  """
  @spec session_named(Project.t(), String.t(), keyword) :: {:ok, Thread.t()} | {:error, term}
  def session_named(%Project{id: project_id} = project, handle, opts \\ []) do
    case get_thread_by_handle(project_id, handle) do
      {:ok, %Thread{status: status} = thread} when status not in [:archived, :unrecoverable] ->
        {:ok, thread}

      _ ->
        start_thread(project, Keyword.take(opts, [:title, :model, :effort]) ++ [handle: handle])
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
      Longx.Agent.Definition.Loader.load(project.root_path,
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
      settings: Longx.Agent.Definition.Settings.for_project(project),
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
  # the agent of a row, from what the row says; a parent's children get their
  # specs registered first (after a restart the specs are gone, the rows not),
  # so its team is listed again and a follow-up revives a child from its row
  defp ensure_agent(%Thread{} = thread, extra \\ []) do
    register_team_specs(thread)
    Longx.Agent.ensure(agent_opts(thread) ++ extra)
  end

  # any thread's: a child's own children too (they spawn to max_depth)
  defp register_team_specs(%Thread{id: id}) do
    for child <- list_subagents!(id),
        Longx.Agent.Kernel.Specs.get(child.kernel_thread_id) == nil do
      task =
        case list_turns!(child) do
          [%Turn{user_text: text} | _] -> text
          _ -> nil
        end

      Longx.Agent.Kernel.Specs.put(
        child.kernel_thread_id,
        agent_opts(child) ++
          [task: task, spawned_at: DateTime.to_unix(child.inserted_at, :microsecond)]
      )
    end

    :ok
  end

  @doc """
  A sub-agent closed by its parent (`close_agent`): its row is archived so
  the team rebuilt from the rows after a restart leaves it out (a closed
  researcher came back beside the new one, two members of one name, and the
  tools' schema was invalid from then on). Nothing when the row is gone.
  """
  @spec archive_agent_row(String.t()) :: :ok
  def archive_agent_row(kernel_thread_id) do
    case get_thread_by_kernel_id(kernel_thread_id) do
      {:ok, %Thread{parent_thread_id: parent} = row} when not is_nil(parent) ->
        archive_thread!(row)
        broadcast_changed(row.project_id)
        :ok

      _ ->
        :ok
    end
  end

  defp agent_opts(%Thread{} = thread) do
    [
      thread_id: thread.kernel_thread_id,
      project_id: thread.project_id,
      cwd: thread.cwd,
      web_search: thread.web_search,
      trust: trust_fun(thread.project_id),
      settings: settings_fun(thread.project_id),
      models: &Longx.AI.model_choices/0,
      idle_ms:
        Longx.Agent.Definition.Settings.idle_ms(
          Longx.Agent.Definition.Settings.for_project_id(thread.project_id)
        ),
      spawner: &__MODULE__.spawn_native_agent/4
    ] ++ model_opts(thread) ++ team_opts(thread)
  end

  # a root thread's model is the person's choice; a sub-agent's row holds what it
  # inherited from the session, which its role's own model outranks
  defp model_opts(%Thread{parent_thread_id: nil} = thread),
    do: [model: thread.model_slug, effort: thread.reasoning_effort]

  defp model_opts(%Thread{} = child),
    do: [inherited_model: child.model_slug, inherited_effort: child.reasoning_effort]

  # read at every turn, like the trust switch
  defp settings_fun(project_id),
    do: fn -> Longx.Agent.Definition.Settings.for_project_id(project_id) end

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
    with {:ok, _to} <- Longx.Agent.Definition.Layout.promote(root, rel) do
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
         # a model given is the child's; else the session's is inherited (the row
         # keeps it, under the role's own — see agent_opts) — else the default
         model_slug = Keyword.get(opts, :model),
         effort = Keyword.get(opts, :effort),
         inherited_model = Keyword.get(opts, :inherited_model),
         inherited_effort = Keyword.get(opts, :inherited_effort),
         {:ok, child} <-
           create_thread(%{
             kernel_thread_id: child_id,
             project_id: parent.project_id,
             parent_thread_id: parent.id,
             agent_path: (parent.agent_path || "/root") <> "/" <> name,
             title: name,
             cwd: Keyword.get(opts, :cwd, parent.cwd),
             model_slug: model_slug || inherited_model,
             reasoning_effort: effort || inherited_effort,
             web_search: parent.web_search,
             status: :active
           }),
         {:ok, _pid} <-
           ensure_agent(
             child,
             [task: String.slice(task, 0, 200), spawned_at: System.os_time(:microsecond)]
             |> put_if(:model, model_slug)
             |> put_if(:effort, effort)
           ),
         :ok <- Tracker.track(child_id),
         {:ok, _turn} <-
           create_turn(%{
             kernel_turn_id: turn_id,
             thread_id: child.id,
             user_text: String.slice(task, 0, 200),
             model_slug: model_slug,
             reasoning_effort: effort,
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
  Sends a user message as a new turn. The working tree is the person's:
  Longx never commits, never looks at whether it is dirty (the per-turn git
  bookmarks and the "before turn" commits of 0.2.x polluted every history
  they touched and bought nothing).
  Options: `model:` (switches the model from here on), `effort:` (the
  level from here on), `images:` (data urls). `{:error, :turn_in_progress}`
  while a turn runs — a message then is a steer (`steer_message/3`).
  """
  @spec send_message(Thread.t(), String.t(), keyword) ::
          {:ok, Turn.t()} | {:error, :turn_in_progress | term}
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
         turn_id = "turn_" <> Ash.UUID.generate(),
         {:ok, turn} <-
           create_turn(%{
             kernel_turn_id: turn_id,
             thread_id: thread.id,
             user_text: text,
             model_slug: model_slug,
             reasoning_effort: effort,
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
  Every root thread with a turn in flight — its own, or one of its
  sub-agents' (the parent is idle while a researcher works; the session is
  busy all the same) — across projects, newest activity first: the welcome
  page's way back into what is running. `waiting` is whether the thread or
  one of its agents holds a question for the person, `working` the names of
  the sub-agents at work.
  """
  @spec running_threads() :: [map]
  def running_threads do
    active = list_all_active_threads!(load: :project)
    roots = Map.new(active, &{&1.id, &1})

    # a working sub-agent makes its root busy: walk up to it (a row a hop at a time)
    {roots, working} =
      Enum.reduce(active, {roots, %{}}, fn
        %Thread{parent_thread_id: nil}, acc ->
          acc

        %Thread{} = child, {roots, working} ->
          case root_of(child) do
            {:ok, %Thread{} = root} ->
              root =
                if Map.has_key?(roots, root.id),
                  do: roots[root.id],
                  else: Ash.load!(root, :project)

              {Map.put_new(roots, root.id, root),
               Map.update(working, root.id, [agent_name(child)], &(&1 ++ [agent_name(child)]))}

            _ ->
              {roots, working}
          end
      end)

    roots
    |> Map.values()
    |> Enum.filter(&is_nil(&1.parent_thread_id))
    |> Enum.sort_by(
      &{&1.last_activity_at || ~U[1970-01-01 00:00:00Z], &1.inserted_at},
      {:desc, DateTime}
    )
    |> Enum.map(fn %Thread{} = thread ->
      agents = Map.get(working, thread.id, [])

      %{
        id: thread.id,
        kernel_thread_id: thread.kernel_thread_id,
        title: thread.title,
        preview: thread.preview,
        last_activity_at: thread.last_activity_at,
        project_id: thread.project_id,
        project_slug: thread.project.slug,
        project_name: thread.project.name,
        waiting:
          Longx.Agent.ThreadState.Store.requests(thread.kernel_thread_id) != [] or
            Enum.any?(active, fn a ->
              a.parent_thread_id != nil and a.project_id == thread.project_id and
                Longx.Agent.ThreadState.Store.requests(a.kernel_thread_id) != [] and
                match?({:ok, %Thread{id: id}} when id == thread.id, root_of(a))
            end),
        working: agents
      }
    end)
  end

  # the root of a sub-agent's row: its parent, its parent's parent…
  defp root_of(%Thread{parent_thread_id: nil} = thread), do: {:ok, thread}

  defp root_of(%Thread{parent_thread_id: parent_id}) do
    case Ash.get(Thread, parent_id) do
      {:ok, %Thread{} = parent} -> root_of(parent)
      {:error, _} = error -> error
    end
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

  @doc "A `Longx.Notify` event about a project as a whole (a watch's news): the page it points at is the project's."
  @spec notify_project(String.t(), String.t(), keyword) :: :ok
  def notify_project(project_id, kind, opts) do
    case Ash.get(Project, project_id) do
      {:ok, %Project{slug: slug, name: name}} ->
        Longx.Notify.push(%{
          kind: kind,
          title: Keyword.fetch!(opts, :title),
          body: Keyword.get(opts, :body) || name,
          url: "/p/#{slug}",
          project_id: project_id,
          thread_id: nil
        })

      {:error, _} ->
        :ok
    end
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
  report waking its parent): a Turn row like one the person sent, so the
  list and the welcome page see it.
  """
  @spec record_external_turn(Thread.t(), String.t(), keyword) :: {:ok, Turn.t()} | {:error, term}
  def record_external_turn(%Thread{} = thread, kernel_turn_id, opts \\ []) do
    # a turn of an agent that is gone (the thread being deleted): no row for it
    if Longx.Agent.whereis(thread.kernel_thread_id),
      do: do_record_external_turn(thread, kernel_turn_id, opts),
      else: {:error, :agent_gone}
  end

  defp do_record_external_turn(%Thread{} = thread, kernel_turn_id, opts) do
    goal = Longx.Agent.ThreadState.Store.meta(thread.kernel_thread_id).goal

    text =
      case {Keyword.get(opts, :from), goal} do
        {"watch-" <> name, _} -> "（定时触发）" <> name
        {_, %{"objective" => objective}} when is_binary(objective) -> "（目标续跑）" <> objective
        _ -> "（agent 消息）"
      end

    with {:ok, turn} <-
           create_turn(%{
             kernel_turn_id: kernel_turn_id,
             thread_id: thread.id,
             user_text: String.slice(text, 0, 200),
             model_slug: thread.model_slug,
             reasoning_effort: thread.reasoning_effort,
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

  # every child row, archived ones included (what the team shows is `list_subagents!`)
  defp all_subagents!(parent_id) do
    Thread
    |> Ash.Query.filter(parent_thread_id == ^parent_id)
    |> Ash.read!()
  end

  @doc """
  Deletes the thread row, its turns, its agent and its transcript (never
  while a turn runs).
  """
  @spec delete_thread(Thread.t()) :: :ok | {:error, term}
  def delete_thread(%Thread{} = thread) do
    thread = Ash.get!(Thread, thread.id)

    with :ok <- refuse_while_running(thread) do
      # the sub-agents first — the closed (archived) ones too: their rows point
      # at this one, and their processes stop with the parent anyway
      for child <- all_subagents!(thread.id), do: delete_rows(child)
      delete_rows(thread)
      broadcast_changed(thread.project_id)
      :ok
    end
  end

  # the thread's spec first (a wake-up arriving now finds no agent to bring
  # back), then its agent, its transcript, its turns and its row; a turn event
  # still on its way to the Tracker finds the agent gone and writes nothing
  # (`record_external_turn`)
  defp delete_rows(%Thread{} = thread) do
    Longx.Agent.Kernel.Specs.delete(thread.kernel_thread_id)
    Longx.Agent.stop(thread.kernel_thread_id)
    Longx.Agent.Transcript.delete!(thread.kernel_thread_id)

    Ash.bulk_destroy!(Ash.Query.filter(Turn, thread_id == ^thread.id), :destroy, %{},
      authorize?: false
    )

    Ash.destroy!(thread)
    :ok
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
        with {:ok, _pid} <- ensure_agent(thread),
             :ok <- seed_turns(thread),
             :ok <- Tracker.track(id),
             do: {:ok, id}

      {:error, _} ->
        {:error, :unknown_thread}
    end
  end

  # the view's turns (stamps, status, usage — the per-turn badge) come from the
  # rows: the store's copy lives in ETS and a restart rebuilt only the items
  defp seed_turns(%Thread{kernel_thread_id: id} = thread) do
    turns =
      for %Turn{status: status} = turn <- list_turns!(thread), status != :reverted, into: %{} do
        {turn.kernel_turn_id,
         %{
           "id" => turn.kernel_turn_id,
           "status" => Atom.to_string(status),
           "startedAt" => epoch(turn.started_at),
           "completedAt" => epoch(turn.completed_at),
           "usage" => turn.usage
         }
         |> Map.reject(fn {_k, v} -> is_nil(v) end)}
      end

    Longx.Agent.ThreadState.seed_turns(id, turns)
  end

  defp epoch(nil), do: nil
  defp epoch(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond) / 1_000_000

  defp ensure_usable(%Thread{status: :unrecoverable}), do: {:error, :thread_unrecoverable}
  defp ensure_usable(%Thread{status: :archived}), do: {:error, :thread_archived}
  defp ensure_usable(_thread), do: :ok

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
