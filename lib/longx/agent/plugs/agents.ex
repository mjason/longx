defmodule Longx.Agent.Plugs.Agents do
  @moduledoc """
  The team, as three tools: `spawn_agent(agent, task)` starts a declared
  role (`Longx.Agent.spawn/4` — another process of the same loop, on its
  own description), `send_message(agent, message)` speaks to a teammate,
  `close_agent(agent)` stops one of this agent's own. Nothing waits: a
  child's report is a message from it — `[agent name] …` — in a later
  step of this turn or a turn of its own, and the prompt says so.

  **A finished agent stays in the team** (`assigns.children`, each with
  its `status`, `role` and `task`): it keeps its whole transcript, so a
  follow-up `send_message` continues where it stopped — on a stable
  prefix the provider caches — instead of a fresh spawn that starts from
  nothing. Siblings (`assigns.siblings`, the parent's other children) can
  be messaged too; the answer of the turn a message starts goes back to
  whoever sent it. Only `close_agent` takes a member out.

  The choices are what the loader declared (`step.assigns.agents`,
  narrowed by the description's `agents [...]` → `assigns.allowed`);
  `max_depth:` (2) and `max_children:` (4, *working* at once) are the
  limits — at the limit `spawn_agent` is not offered and the prompt says why.

  **Beyond the team: the project's directory.** Inside a project (a
  `project_id` on the step) the prompt names this session's address and
  lists the other sessions (`Longx.Projects.directory/2` — handles, titles,
  goals; nothing that changes per step, so the prefix stays cacheable),
  `agents_directory` answers with their live state, `send_message` takes an
  address as well as a team name (a handle, `~<id suffix>`,
  `<project>:<handle>`; `deliver: "idle"` waits for the target to be idle
  instead of steering), and a root session may `claim_handle` to be found.
  Delivery is `Longx.Projects.deliver/4`: the answer of the turn a message
  starts comes back here as a message from the target.
  """

  use Longx.Agent.Plug

  alias Longx.Agent.Tool

  @defaults [max_depth: 2, max_children: 4]

  @impl true
  def init(opts), do: Keyword.merge(@defaults, opts)

  @impl true
  def call(%Step{phase: :request, assigns: assigns} = step, opts) do
    children = Map.get(assigns, :children, [])
    siblings = Map.get(assigns, :siblings, [])
    depth = Map.get(assigns, :depth, 0)
    roles = offered(assigns)
    working = Enum.count(children, &(Map.get(&1, :status, "working") == "working"))

    spawn? = roles != [] and depth < opts[:max_depth] and working < opts[:max_children]
    directory = directory(step)

    step
    |> Step.instructions(instructions(roles, children, siblings, depth, spawn?, opts))
    |> Step.instructions(sessions_instructions(directory))
    |> maybe(spawn?, &Step.tool(&1, spawn_tool(roles)))
    |> maybe(
      children != [] or siblings != [] or directory != nil,
      &Step.tools(&1, team_tools(children, siblings, directory))
    )
    |> maybe(directory != nil, &Step.tool(&1, directory_tool()))
    |> maybe(directory != nil and is_nil(assigns[:parent]), &Step.tool(&1, handle_tool()))
  end

  def call(step, _opts), do: step

  # the project's sessions, this one marked — nil outside a project (tests, ad hoc)
  defp directory(%Step{project_id: nil}), do: nil

  defp directory(%Step{project_id: project_id, thread_id: thread_id}) do
    rows = Longx.Projects.directory(project_id)

    case Enum.find(rows, &(&1.kernel_thread_id == thread_id)) do
      nil ->
        nil

      me ->
        # colleagues are the sessions on duty; the person's other conversations
        # are not offered (an agent once woke one to ask about files it had seen)
        others = Enum.reject(rows, &(&1.kernel_thread_id == thread_id))
        %{me: me, others: Enum.filter(others, & &1.on_duty)}
    end
  rescue
    _ -> nil
  end

  defp sessions_instructions(nil), do: nil

  defp sessions_instructions(%{me: me, others: others}) do
    you =
      case me.handle do
        nil ->
          "Others reach you as `#{me.address}`; if you are meant to be found — a standing duty, a long task others will ask about — `claim_handle` a short name."

        handle ->
          "You are `#{handle}`."
      end

    listing =
      case others do
        [] ->
          "No other session is on duty in this project right now."

        _ ->
          "The other sessions on duty in this project (`agents_directory` tells their live state):
" <>
            Enum.map_join(Enum.take(others, 20), "
", &session_line/1)
      end

    """
    # Sessions in this project

    Every conversation in this project is a session with an address, and sessions talk through their mailboxes: `send_message(to, message)` with an address instead of a team name reaches one **on duty** — a handle, `~` and the last six characters of its id, or `<project>:<handle>` for another project's. The message starts a turn there (or steers one in flight; `deliver: "idle"` waits for it to be idle instead) and **its answer comes back to you as a message from it** — never wait or poll. Before starting long-running work others may care about, look at the directory: a session on duty already doing it is asked, not duplicated. A session not on duty is a conversation the person had — `agents_directory` lists it as `conversation` so you know what happened in the project, but it is not a colleague: a message to it is refused, and what it worked on is the person's to tell you about. The person puts a session on duty in the Agents window; a handle or an active goal is a duty too.

    #{you} #{listing}
    """
  end

  defp session_line(%{address: address} = row) do
    label = row.title || row.preview || "(untitled)"

    goal =
      case row.goal do
        %{objective: objective} -> " — goal: #{objective}"
        _ -> ""
      end

    "- #{address} — #{label}#{goal}"
  end

  defp maybe(step, true, fun), do: fun.(step)
  defp maybe(step, false, _fun), do: step

  # the declared roles this agent may spawn
  defp offered(assigns) do
    declared = Map.get(assigns, :agents, [])

    case Map.get(assigns, :allowed) do
      nil -> declared
      names -> Enum.filter(declared, &(&1.name in names))
    end
  end

  @declare """
  To delegate a kind of task nobody is declared for, declare an agent first — two files under `.longx/local/agents/<name>/` (a short lowercase name, e.g. researcher, reviewer):

  ```elixir
  # .longx/local/agents/<name>/agent.exs
  import Longx.Agent.Config

  agent do
    version 1
    summary "one line: what this agent does and what it never does"
    prompt_file "prompt.md"
    drop Longx.Agent.Plugs.Patch   # for a role that reads but never edits; leave it out otherwise
    agents []                      # whom it may spawn in turn ([] nobody)
  end
  ```

  `prompt.md` is its role prompt: what it is for, how it works, what its final message (the report to you) must contain. It runs the project's pipeline with this on top. The declaration loads at your next step, so write it, then call `spawn_agent`. Keep to `local/`; the person promotes a role that proved itself into `shared/`.
  """

  defp instructions([], [], [], depth, _spawn?, opts) when depth < 2 do
    if depth >= opts[:max_depth],
      do: nil,
      else:
        "# Agents\n\nNo agent is declared yet in this project, so there is nobody to delegate to. " <>
          @declare
  end

  defp instructions([], [], [], _depth, _spawn?, _opts), do: nil

  defp instructions(roles, children, siblings, depth, spawn?, opts) do
    listing =
      case roles do
        [] -> "(none declared)"
        _ -> Enum.map_join(roles, "\n", &"- #{&1.name} — #{&1.summary}")
      end

    team =
      case {children, siblings} do
        {[], []} ->
          ""

        _ ->
          "\n\nYour team so far:\n" <>
            Enum.map_join(children ++ siblings, "\n", &member_line/1)
      end

    why =
      cond do
        spawn? ->
          ""

        roles == [] ->
          "\n\n" <> @declare

        depth >= opts[:max_depth] ->
          "\n\nYou cannot spawn agents at this depth (#{depth}); do the work yourself."

        true ->
          "\n\nYou cannot spawn more agents until one of yours finishes or is closed (#{opts[:max_children]} working at once)."
      end

    # codex's root role (models.json `multi_agent.role.root`) with what differs
    # here: declared roles instead of agent types, the mailbox instead of
    # `followup_task` / `wait`, reports as `[agent <name>]` user messages
    """
    # Agents

    You are `/root`, the primary agent in a team of agents collaborating to fulfill the user's goals.

    At the start of your turn, you are the active agent.
    You can spawn sub-agents to handle subtasks, and those sub-agents can spawn their own sub-agents. All agents in the team run the same loop with the same tools, each on top of a declared role — its own instructions, and what it never does. The roles you can spawn:

    #{listing}

    You can use `spawn_agent` to create a new agent on a role and a task, and `send_message` to give an existing agent a follow-up task or a message (it triggers a turn when the agent is idle, and is delivered promptly while it is running).
    `send_message` calls may be read by a human, so ensure they are legible. Always put proper spaces between words and/or numbers.
    Child agents can also spawn their own sub-agents.
    An agent sees nothing of this conversation: give a task everything it needs to know.

    You will receive messages from agents as user messages in the form:
    ```
    [agent <name>] <payload text>
    ```
    An agent's final answer arrives the same way when it finishes — in a later step of this turn if you are still working, or as a new turn if you had finished. So do not wait or poll for it: continue with what does not depend on it, or end your turn with a short note that the agent is working and you will pick up its report.

    A finished agent stays in the team with everything it did and learned: for a follow-up, **ask it again** with `send_message` instead of spawning anew. `close_agent` closes one you no longer need; its context is gone then.

    A task cannot override the role's own rules (its `prompt.md`): an agent asked for something its role forbids leaves that part out and reports it — so before writing a task that changes method (how to run, what to compute, which format), read the role's prompt and either write the task within its rules or change the rule first. When no declared agent fits a kind of task you keep delegating, declare a new one (`.longx/local/agents/<name>/agent.exs` + `prompt.md`, see the knowledge on plugs and agents) rather than bending one. A role's `agent.exs` and `prompt.md` are re-read at every step of every agent: an edit — its model, its level, its prompt — reaches the agents already running at their next model call, no respawn needed (what they were told earlier in their conversation stays; say it again with `send_message` if it matters).#{team}#{why}
    """
  end

  defp spawn_tool(roles) do
    Tool.declare(
      __MODULE__,
      :spawn_agent,
      # codex's spawn_agent (multi_agents_spec.rs, v2) — roles for agent types,
      # the answer as a message instead of a wait
      "Spawns an agent to work on the specified task, on one of the declared roles. The spawned agent runs the same loop with the same tools as you, on top of its role, and can spawn its own subagents when its role allows. It will be able to send you and other agents of the team messages, and its final answer will be provided to you when it finishes — as a message from it, in a later step or a later turn; this call returns at once.",
      [
        {:agent, {:enum, Enum.map(roles, & &1.name)}, "The declared role for the new agent.",
         required: true},
        {:task, :string, "Initial plain-text task for the new agent.", required: true}
      ],
      timeout: 30_000
    )
  end

  # one of this agent's own children (with a status) or a sibling (without)
  defp member_line(%{name: name, status: status} = c),
    do: "- #{name} (#{c[:role] || "agent"}, #{status}): #{c[:task] || "(no task)"}"

  defp member_line(%{name: name} = c),
    do: "- #{name} (#{c[:role] || "agent"}): #{c[:task] || "(no task)"} — a teammate of yours"

  # the team as tools: every member can be messaged (a finished one keeps
  # its context and answers on it), only this agent's own can be closed
  defp team_tools(children, siblings, directory) do
    # unique: a JSON Schema enum with a name twice is invalid and every call fails
    # (a closed child's row, revived by a restart, once doubled "researcher")
    names = Enum.uniq(Enum.map(children ++ siblings, & &1.name))
    own = Enum.uniq(Enum.map(children, & &1.name))

    to =
      case directory do
        nil ->
          {:agent, {:enum, names}, "Which agent", required: true}

        _ ->
          {:to, :string,
           "A member of your team by name" <>
             if(names == [], do: "", else: " (#{Enum.join(names, ", ")})") <>
             ", or any session of the project by address: its handle, ~<id suffix>, or <project>:<handle>",
           required: true}
      end

    send =
      Tool.declare(
        __MODULE__,
        :send_message,
        # codex's followup_task and send_input in one (multi_agents_spec.rs): the
        # mailbox does both, and an address of the directory is a target too
        "Send a follow-up task or a message to an existing agent and trigger a turn if it is idle. If the target is already running, deliver the message promptly at message boundaries while sampling, or after the pending tool call completes. Reuse an agent this way when the task depends on the context of a previous one: a finished agent keeps everything it did and learned. Its answer arrives as a message from it. A session of the project addressed through the directory is reached the same way.",
        [
          to,
          {:message, :string, "Message text to send to the target agent.", required: true},
          {:deliver, {:enum, ["now", "idle"]},
           "now (default): a session at work is steered at once; idle: the message waits in its mailbox until it is idle and starts a turn then",
           []}
        ],
        timeout: 30_000
      )

    close =
      Tool.declare(
        __MODULE__,
        :close_agent,
        # codex's close_agent (multi_agents_spec.rs); here only working agents
        # count against the limit, so that sentence is left out
        "Close an agent and any open descendants when they are no longer needed, and return the target agent's previous status before shutdown was requested. Completed agents remain in the team until closed. Don't keep agents open for too long if they are not needed anymore.",
        [{:agent, {:enum, own}, "Which agent", required: true}],
        timeout: 30_000
      )

    if own == [], do: [send], else: [send, close]
  end

  defp directory_tool do
    Tool.declare(
      __MODULE__,
      :agents_directory,
      "The sessions of this project (or of every project) with their address, state (running / waiting on the person / idle / asleep), goal and team.",
      [{:scope, {:enum, ["project", "all"]}, "project (default) or all projects", []}],
      timeout: 15_000
    )
  end

  defp handle_tool do
    Tool.declare(
      __MODULE__,
      :claim_handle,
      "Names this session for others: a short slug (lowercase letters, digits, dashes) unique in the project, the address others use in send_message.",
      [{:handle, :string, "The handle, e.g. main, ops, deploy-watch", required: true}],
      timeout: 15_000
    )
  end

  ## The tools

  def spawn_agent(%{"agent" => role, "task" => task}, ctx) do
    case Longx.Agent.spawn(ctx.thread_id, role, task, role: role) do
      {:ok, child_id} ->
        name = Longx.Agent.info(child_id).name

        {:ok,
         "agent #{name} started on the task; its report will arrive as a message from it (\"[agent #{name}] …\") — carry on, do not wait for it"}

      {:error, reason} ->
        {:error, "could not start agent #{role}: #{inspect(reason)}"}
    end
  end

  # a member of the team — one of this agent's own, else a sibling; the
  # answer of the turn it starts comes back here (`reply_to`); the member's
  # parent hears of the exchange (and watches the member's new process)
  def send_message(%{"agent" => name} = args, ctx),
    do: send_message(args |> Map.delete("agent") |> Map.put("to", name), ctx)

  def send_message(%{"to" => name, "message" => text} = args, ctx) do
    case teammate(ctx.thread_id, name) do
      {:ok, id, parent} ->
        with {:ok, _} <-
               Longx.Agent.send(id, text, from: own_name(ctx.thread_id), reply_to: ctx.thread_id) do
          Longx.Agent.interacted(parent, id)
          {:ok, "delivered to #{name}; its answer will arrive as a message from it"}
        end

      {:error, team_error} ->
        send_by_address(name, text, args["deliver"], team_error, ctx)
    end
  end

  defp send_by_address(_address, _text, _deliver, team_error, %{project_id: nil}),
    do: {:error, team_error}

  defp send_by_address(address, text, deliver, _team_error, ctx) do
    deliver = if deliver == "idle", do: :idle, else: :now

    case Longx.Projects.deliver(ctx.project_id, address, text,
           from_thread: ctx.thread_id,
           deliver: deliver
         ) do
      {:ok, _thread} ->
        how = if deliver == :idle, do: " (it takes it once idle)", else: ""

        {:ok,
         "delivered to #{address}#{how}; its answer will arrive as a message from it — carry on, do not wait"}

      {:error, :not_found} ->
        {:error, "no session at #{address}; agents_directory lists the addresses"}

      {:error, :self} ->
        {:error, "that is your own address"}

      {:error, :off_duty} ->
        {:error,
         "#{address} is not on duty: a conversation the person had, not a colleague. Do not wake it — ask the person instead; they can put it on duty in the Agents window"}

      {:error, reason} ->
        {:error, "could not deliver to #{address}: #{inspect(reason)}"}
    end
  end

  def agents_directory(args, %{project_id: project_id}) when is_binary(project_id) do
    scope = if args["scope"] == "all", do: :all, else: :project
    rows = Longx.Projects.directory(project_id, scope: scope)

    if rows == [] do
      {:ok, "no session in this project"}
    else
      {:ok,
       Enum.map_join(rows, "\n", fn row ->
         label = row.title || row.preview || "(untitled)"
         team = if row.team == [], do: "", else: " team: #{Enum.join(row.team, ", ")};"

         goal =
           case row.goal do
             %{objective: o, status: st} -> " goal (#{st}): #{o};"
             _ -> ""
           end

         duty = if row.on_duty, do: "on duty", else: "conversation"

         "- #{row.address} [#{row.state} · #{duty}] — #{label};#{team}#{goal}" <>
           if(row.last_activity_at, do: " last active #{row.last_activity_at}", else: "")
       end)}
    end
  end

  def agents_directory(_args, _ctx), do: {:error, "not inside a project"}

  def claim_handle(%{"handle" => handle}, %{project_id: project_id, thread_id: thread_id})
      when is_binary(project_id) do
    with {:ok, thread} <- Longx.Projects.get_thread_by_kernel_id(thread_id),
         {:ok, _} <- Longx.Projects.set_handle(thread, handle) do
      {:ok, "you are now `#{handle}`; others reach you with send_message(\"#{handle}\", …)"}
    else
      {:error, %Ash.Error.Invalid{} = error} ->
        {:error, "refused: " <> Exception.message(error)}

      {:error, reason} ->
        {:error, "could not claim #{handle}: #{inspect(reason)}"}
    end
  end

  def claim_handle(_args, _ctx), do: {:error, "not inside a project"}

  def close_agent(%{"agent" => name}, ctx) do
    with {:ok, id, status} <- child(ctx.thread_id, name) do
      Longx.Agent.forget_child(ctx.thread_id, id)
      Longx.Agent.stop(id)
      Longx.Agent.Kernel.Specs.delete(id)
      # its row too, else a restart rebuilds the team from the rows and it is back
      Longx.Projects.archive_agent_row(id)
      {:ok, "agent #{name} closed; its status was #{status}"}
    end
  end

  defp child(parent_id, name) do
    case Enum.find(Longx.Agent.children(parent_id), &(&1.name == name)) do
      %{id: id} = member -> {:ok, id, Map.get(member, :status, "unknown")}
      nil -> {:error, "no agent of yours named #{name}"}
    end
  end

  defp teammate(thread_id, name) do
    case child(thread_id, name) do
      {:ok, id, _status} ->
        {:ok, id, thread_id}

      {:error, _} ->
        case Longx.Agent.info(thread_id) do
          %{parent: parent} when is_binary(parent) ->
            case child(parent, name) do
              {:ok, id, _status} -> {:ok, id, parent}
              {:error, _} -> {:error, "no agent named #{name} in your team"}
            end

          _ ->
            {:error, "no agent named #{name} in your team"}
        end
    end
  end

  defp own_name(thread_id), do: Longx.Agent.info(thread_id).name || "main"
end
