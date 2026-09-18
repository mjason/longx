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

    step
    |> Step.instructions(instructions(roles, children, siblings, depth, spawn?, opts))
    |> maybe(spawn?, &Step.tool(&1, spawn_tool(roles)))
    |> maybe(children != [] or siblings != [], &Step.tools(&1, team_tools(children, siblings)))
  end

  def call(step, _opts), do: step

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
          "\n\nYour team so far — each keeps everything it did and learned, so **ask it again** with `send_message` instead of spawning anew for a follow-up:\n" <>
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

    """
    # Agents

    You may delegate to these agents, each a separate process with its own instructions and tools:

    #{listing}

    `spawn_agent(agent, task)` starts one on a task and returns at once. **Its report arrives later as a message from it** — a user message beginning `[agent <name>]` — in a later step of this turn if you are still working, or as a new turn if you had finished. So do not wait or poll for it: continue with what does not depend on it, or end your turn with a short note that the agent is working and you will pick up its report. `send_message(agent, message)` speaks to a member of your team — a follow-up question to one that finished (it answers on its kept context), more context or a redirection to one still working, a question to a teammate; the answer arrives as a message from it, like a report. `close_agent(agent)` stops one of yours you no longer need — its context is gone then. Give a task everything the agent needs to know, since it sees nothing of this conversation. When no declared agent fits a kind of task you keep delegating, declare a new one (`.longx/local/agents/<name>/agent.exs` + `prompt.md`, see the knowledge on plugs and agents) rather than bending one.#{team}#{why}
    """
  end

  defp spawn_tool(roles) do
    Tool.declare(
      __MODULE__,
      :spawn_agent,
      "Starts a sub-agent on a task; returns at once, the agent's report comes back later as a message from it.",
      [
        {:agent, {:enum, Enum.map(roles, & &1.name)}, "Which declared agent", required: true},
        {:task, :string, "The task, complete and self-contained", required: true}
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
  defp team_tools(children, siblings) do
    names = Enum.map(children ++ siblings, & &1.name)
    own = Enum.map(children, & &1.name)

    send =
      Tool.declare(
        __MODULE__,
        :send_message,
        "Sends a message to a member of your team. An agent keeps everything it did and learned, so a follow-up question to a finished one continues where it stopped; one still working takes it as more context or a redirection. Its answer comes back as a message from it.",
        [
          {:agent, {:enum, names}, "Which agent", required: true},
          {:message, :string, "What to tell or ask it", required: true}
        ],
        timeout: 30_000
      )

    close =
      Tool.declare(
        __MODULE__,
        :close_agent,
        "Stops one of your agents and forgets it; its unfinished work and its context are gone.",
        [{:agent, {:enum, own}, "Which agent", required: true}],
        timeout: 30_000
      )

    if own == [], do: [send], else: [send, close]
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
  def send_message(%{"agent" => name, "message" => text}, ctx) do
    with {:ok, id, parent} <- teammate(ctx.thread_id, name),
         {:ok, _} <-
           Longx.Agent.send(id, text, from: own_name(ctx.thread_id), reply_to: ctx.thread_id) do
      Longx.Agent.interacted(parent, id)
      {:ok, "delivered to #{name}; its answer will arrive as a message from it"}
    end
  end

  def close_agent(%{"agent" => name}, ctx) do
    with {:ok, id} <- child(ctx.thread_id, name) do
      Longx.Agent.forget_child(ctx.thread_id, id)
      Longx.Agent.stop(id)
      Longx.Agent.Kernel.Specs.delete(id)
      {:ok, "agent #{name} closed"}
    end
  end

  defp child(parent_id, name) do
    case Enum.find(Longx.Agent.children(parent_id), &(&1.name == name)) do
      %{id: id} -> {:ok, id}
      nil -> {:error, "no agent of yours named #{name}"}
    end
  end

  defp teammate(thread_id, name) do
    case child(thread_id, name) do
      {:ok, id} ->
        {:ok, id, thread_id}

      {:error, _} ->
        case Longx.Agent.info(thread_id) do
          %{parent: parent} when is_binary(parent) ->
            case child(parent, name) do
              {:ok, id} -> {:ok, id, parent}
              {:error, _} -> {:error, "no agent named #{name} in your team"}
            end

          _ ->
            {:error, "no agent named #{name} in your team"}
        end
    end
  end

  defp own_name(thread_id), do: Longx.Agent.info(thread_id).name || "main"
end
