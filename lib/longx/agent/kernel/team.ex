defmodule Longx.Agent.Kernel.Team do
  @moduledoc false
  # The agent as a parent: spawning children, naming them, the depth limit, what the parent's view shows of them, the child's report.

  alias Longx.Agent.Kernel.State
  import Longx.Agent.Kernel.State

  @max_hops 6

  def with_activity(state, nil), do: state
  def with_activity(state, {child_id, name, kind}), do: activity(state, child_id, name, kind)

  # what the parent's view shows of a child: codex's subAgentActivity
  def activity(%State{} = state, child_id, name, kind) do
    ui = %{
      "id" => new_id("item"),
      "type" => "subAgentActivity",
      "turnId" => state.turn_id,
      "agentThreadId" => child_id,
      "agentPath" => state.path <> "/" <> name,
      "kind" => kind
    }

    emit(state, "item/started", %{"item" => ui, "turnId" => state.turn_id})
    append(state, :activity, %{"type" => "longx_activity"}, ui, context?: false)
  end

  ## Children

  @default_max_depth 2

  def spawn_child(%State{} = state, name, task, opts) do
    spawner = Keyword.get(opts, :spawner) || state.spawner || configured_spawner()
    name = unique_name(state, name)

    # the session's model and level go with the child, under its own role's
    # and a spawn option's (what this agent runs on, or what it inherited itself)
    opts =
      opts
      |> Keyword.put_new(:inherited_model, state.model || state.inherited_model)
      |> Keyword.put_new(
        :inherited_effort,
        if(state.model, do: state.effort, else: state.inherited_effort)
      )

    with :ok <- depth_ok(state),
         {:ok, child_id} <- spawner.(state, name, task, opts),
         pid when is_pid(pid) <- Longx.Agent.whereis(child_id) || {:error, :not_started} do
      child =
        member(state, name, pid, :working, Keyword.get(opts, :role), summary(task))

      state = %{state | children: Map.put(state.children, child_id, child)}
      {:ok, child_id, activity(state, child_id, name, "started")}
    end
  end

  # a team member: its process when alive, what it is and what it was given;
  # `n` keeps the order the team was made in. Two monitors: the agent's pid
  # (`ref`) and its guard (`guard_ref`, `Longx.Agent.Guard`), which stands
  # across the child's restarts — a crash is remembered (`crashed`) until the
  # guard either brings the child back or gives up (both end in `:shutdown`,
  # so the guard's exit alone cannot tell the two apart)
  defp member(%State{children: children}, name, pid, status, role, task) do
    %{
      name: name,
      pid: pid,
      ref: if(pid, do: Process.monitor(pid)),
      guard_ref: if(pid, do: watch_guard(pid)),
      crashed: false,
      status: status,
      role: role,
      task: task,
      n: map_size(children) + 1
    }
  end

  @summary_bytes 200
  defp summary(task) when is_binary(task) do
    task |> String.split("\n", parts: 2) |> hd() |> String.slice(0, @summary_bytes)
  end

  defp summary(_task), do: nil

  # a child's status: its turn ended (done), it left idle (still done: it comes
  # back with its transcript), it crashed (failed) — a member until closed
  def mark(%State{children: children} = state, child_id, status, pid \\ :keep) do
    case Map.get(children, child_id) do
      nil ->
        state

      child ->
        child =
          case pid do
            :keep ->
              %{child | status: status}

            nil ->
              %{child | status: status, pid: nil, ref: nil}

            pid ->
              %{
                child
                | status: status,
                  pid: pid,
                  ref: Process.monitor(pid),
                  guard_ref: child[:guard_ref] || watch_guard(pid),
                  crashed: false
              }
          end

        %{state | children: Map.put(children, child_id, child)}
    end
  end

  @doc "A crash of the child's process noted; its guard restarts it (or gives up: the guard's own exit)."
  def crashed(%State{children: children} = state, child_id) do
    case Map.get(children, child_id) do
      nil ->
        state

      child ->
        %{
          state
          | children: Map.put(children, child_id, %{child | crashed: true, pid: nil, ref: nil})
        }
    end
  end

  # the guard over an agent's pid when it has one (a test's bare agent has none)
  defp watch_guard(pid) do
    case Registry.keys(Longx.Agent.Registry, pid) do
      [thread_id | _] when is_binary(thread_id) ->
        case Longx.Agent.Guard.whereis(thread_id) do
          guard when is_pid(guard) -> Process.monitor(guard)
          nil -> nil
        end

      _ ->
        nil
    end
  end

  @doc "A word to the parent from this agent itself (a restart after a crash): `[agent name] …` in its mailbox, or a turn of its own when it left."
  def notify_parent(%State{parent: nil}, _text), do: :ok

  def notify_parent(%State{parent: parent, name: name}, text) do
    case Longx.Agent.whereis(parent) do
      pid when is_pid(pid) ->
        Kernel.send(pid, {:agent_message, name, text, "report"})

      nil ->
        Task.Supervisor.start_child(Longx.Agent.TaskSupervisor, fn ->
          Longx.Agent.send(parent, text, from: name, kind: "report")
        end)
    end

    :ok
  end

  # a child spoken to again: alive again (revived by `Longx.Agent.send/3`)
  # under a new pid — monitored anew — and working
  def rewatch(%State{children: children} = state, child_id) do
    case {Map.get(children, child_id), Longx.Agent.whereis(child_id)} do
      {nil, _} ->
        state

      {%{pid: pid}, pid} when is_pid(pid) ->
        mark(state, child_id, :working)

      {%{ref: ref} = child, new_pid} ->
        if ref, do: Process.demonitor(ref, [:flush])
        # a new process may sit under a new guard (revived after its guard gave up)
        if child[:guard_ref], do: Process.demonitor(child[:guard_ref], [:flush])
        state = %{state | children: Map.put(children, child_id, %{child | guard_ref: nil})}
        mark(state, child_id, :working, new_pid)
    end
  end

  def forget(%State{children: children} = state, child_id) do
    case Map.pop(children, child_id) do
      {nil, _} ->
        state

      {%{ref: ref} = child, rest} ->
        if ref, do: Process.demonitor(ref, [:flush])
        if child[:guard_ref], do: Process.demonitor(child[:guard_ref], [:flush])
        %{state | children: rest}
    end
  end

  # the team, rebuilt from the specs after this agent left and came back:
  # every agent spawned under it, alive or not, in the order they were made
  def restore_children(%State{thread_id: id} = state) do
    Longx.Agent.Kernel.Specs.children_of(id)
    |> Enum.reduce(state, fn {child_id, opts}, acc ->
      pid = Longx.Agent.whereis(child_id)
      status = if pid && running?(child_id), do: :working, else: :done

      child =
        member(
          acc,
          Keyword.get(opts, :name),
          pid,
          status,
          Keyword.get(opts, :role),
          Keyword.get(opts, :task)
        )

      %{acc | children: Map.put(acc.children, child_id, child)}
    end)
  end

  # from the view in ETS, never a call: this runs in the parent's init, and a
  # child reporting to a parent that had left is blocked inside `ensure_alive`
  # (the start of this very process) — a call to it would wait the whole timeout
  # and then call it done while it works
  defp running?(child_id),
    do: match?(%{"status" => "inProgress"}, Longx.Agent.ThreadState.Store.meta(child_id).turn)

  # the parent's other children, from the specs (an ETS read, never a call
  # to the parent — it may be calling this agent at the same time)
  def siblings(%State{parent: nil}), do: []

  def siblings(%State{parent: parent, thread_id: id}) do
    for {child_id, opts} <- Longx.Agent.Kernel.Specs.children_of(parent), child_id != id do
      %{
        id: child_id,
        name: Keyword.get(opts, :name),
        role: Keyword.get(opts, :role),
        task: Keyword.get(opts, :task),
        path: Keyword.get(opts, :path)
      }
    end
  end

  # a team nests only so deep, whoever asks (the settings' max_depth, else the kernel's)
  def depth_ok(%State{depth: depth, settings: settings}) do
    limit =
      case settings && settings.() do
        %{max_depth: n} when is_integer(n) -> n
        _ -> Application.get_env(:longx, Longx.Agent, [])[:max_depth] || @default_max_depth
      end

    if depth < limit, do: :ok, else: {:error, :too_deep}
  end

  # a second helper is helper-2: names are unique among the live children
  def unique_name(%State{children: children}, name) do
    taken = children |> Map.values() |> Enum.map(& &1.name)

    if name in taken,
      do: Enum.find(Stream.map(2..1000, &"#{name}-#{&1}"), &(&1 not in taken)),
      else: name
  end

  # how a child is made when the agent was given no `spawner:`:
  # `config :longx, Longx.Agent, spawner:`, else a bare agent
  def configured_spawner,
    do:
      :longx
      |> Application.get_env(Longx.Agent, [])
      |> Keyword.get(:spawner, &__MODULE__.bare_spawner/4)

  @doc false
  def bare_spawner(%State{} = parent, name, task, opts) do
    child_id = "native_" <> Ash.UUID.generate()

    with {:ok, _pid} <-
           Longx.Agent.ensure(
             thread_id: child_id,
             parent: parent.thread_id,
             name: name,
             project_id: parent.project_id,
             cwd: Keyword.get(opts, :cwd, parent.cwd),
             # no model given: the role's own, else the session's (inherited), else the default
             model: Keyword.get(opts, :model),
             effort: Keyword.get(opts, :effort),
             inherited_model: Keyword.get(opts, :inherited_model),
             inherited_effort: Keyword.get(opts, :inherited_effort),
             role: Keyword.get(opts, :role),
             task: summary(task),
             spawned_at: System.os_time(:microsecond),
             depth: parent.depth + 1,
             path: parent.path <> "/" <> name,
             pipeline: Keyword.get(opts, :pipeline, parent.pipeline),
             trust: parent.trust,
             web_search: parent.web_search,
             spawner: parent.spawner,
             settings: parent.settings,
             models: parent.models,
             idle_ms: parent.idle_ms
           ),
         {:ok, _} <- Longx.Agent.send(child_id, task) do
      {:ok, child_id}
    end
  end

  # the team as the plugs and the UI see it, in the order it was made
  def children_list(%State{children: children}) do
    children
    |> Enum.sort_by(fn {_id, c} -> c.n end)
    |> Enum.map(fn {id, c} ->
      %{id: id, name: c.name, status: Atom.to_string(c.status), role: c.role, task: c.task}
    end)
  end

  # what this agent is told about being someone's child
  def team_instructions(%State{parent: nil}), do: []

  # codex's subagent role (models.json `multi_agent.role.subagent`) with what
  # differs here: a name and a role instead of a task path, messages as
  # `[agent <name>]` user messages, and the rule that the role's prompt wins
  def team_instructions(%State{name: name, path: path}) do
    # codex names every agent by its canonical task name (`/root/task1/task_3`):
    # the parent is the path above; a coder-3 told only its name once took the
    # sibling `coder` for the main agent and reported to it
    parent_path = path |> String.split("/") |> Enum.drop(-1) |> Enum.join("/")

    [
      """
      You are an agent in a team of agents collaborating to complete a task. Your name is `#{name}` and your identity is `#{path}`: the agent above you in that path (`#{parent_path}`) is your parent, the one that spawned you and gave you the task you are working on.

      You can spawn sub-agents to handle subtasks when your role declares agents, and those sub-agents can spawn their own sub-agents. All agents in the team run the same loop with the same tools, each on top of its declared role.

      You can use `spawn_agent` to create a new agent and `send_message` to pass a message or a follow-up task to a member of your team.
      `send_message` calls may be read by a human, so ensure they are legible. Always put proper spaces between words and/or numbers.

      When you finish your turn, your final message is immediately delivered back to your parent agent (or to the teammate whose message started this turn) — it is all that agent sees of your work, so make it complete and self-contained (facts, sources, what you changed, what is open). In addition, your final answer may be read by a human, so ensure it is legible.

      You will receive messages from other agents as user messages in the form `[agent <name>] <payload text>`.

      Your role's instructions (this prompt) take precedence over the task: where the task asks for something they forbid or a method they rule out, do not comply — do the rest, and say in your report exactly what you left out and which rule it hit, so the other agent can rewrite the task or the person can change the rule.
      """
    ]
  end

  # the child's turn ended: its final message (or its failure) goes to whoever
  # started the turn — a teammate that asked (`reply_to`), else the parent
  def report_to_parent(%State{parent: nil, reply_to: nil}, _status, _error), do: :ok

  # an exchange that bounced too often ends here: no answer to the answer
  def report_to_parent(%State{hops: hops}, _status, _error) when hops >= @max_hops, do: :ok

  def report_to_parent(
        %State{parent: parent, reply_to: reply_to, hops: hops} = state,
        status,
        error
      ) do
    # a failure's words are a provider's or a tool's, verbatim in a code fence: a
    # report is drawn as markdown, and "https://***.com/***" once came out as bold
    # and italics with the stars eaten
    report =
      case {status, error} do
        {"completed", _} -> last_answer(state) || "(no answer)"
        {other, %{"message" => message}} -> "#{other}:\n```\n#{message}\n```"
        {other, _} -> "#{other}:\n```\n#{error || "no details"}\n```"
      end

    name = state.reply_as || state.name
    target = reply_to || parent
    # to the asker it is the answer to its question; to the parent the report of the task
    kind = if reply_to, do: "answer", else: "report"

    case Longx.Agent.whereis(target) do
      pid when is_pid(pid) ->
        Kernel.send(pid, {:agent_message, name, report, kind})

      nil ->
        # the asker left idle meanwhile: bring it back with the report — from a
        # task, since a GenServer.call from inside this callback could meet the
        # asker calling us (its stop asks children first) and wait 15 s for nothing
        Task.Supervisor.start_child(Longx.Agent.TaskSupervisor, fn ->
          Longx.Agent.send(target, report, from: name, hops: hops + 1, kind: kind)
        end)
    end

    :ok
  end

  def last_answer(%State{transcript: transcript}) do
    transcript
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{"type" => "message", "role" => "assistant"} = m -> message_text(m)
      _ -> nil
    end)
  end
end
