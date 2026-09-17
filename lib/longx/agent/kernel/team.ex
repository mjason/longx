defmodule Longx.Agent.Kernel.Team do
  @moduledoc false
  # The agent as a parent: spawning children, naming them, the depth limit, what the parent's view shows of them, the child's report.

  alias Longx.Agent.Kernel.State
  import Longx.Agent.Kernel.State

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

    with :ok <- depth_ok(state),
         {:ok, child_id} <- spawner.(state, name, task, opts),
         pid when is_pid(pid) <- Longx.Agent.whereis(child_id) || {:error, :not_started} do
      ref = Process.monitor(pid)
      child = %{name: name, pid: pid, ref: ref}
      state = %{state | children: Map.put(state.children, child_id, child)}
      {:ok, child_id, activity(state, child_id, name, "started")}
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
             # no model given: the role's own, else the default (not the parent's)
             model: Keyword.get(opts, :model),
             effort: Keyword.get(opts, :effort),
             role: Keyword.get(opts, :role),
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

  def children_list(%State{children: children}),
    do: Enum.map(children, fn {id, %{name: name}} -> %{id: id, name: name} end)

  # what this agent is told about being someone's child
  def team_instructions(%State{parent: nil}), do: []

  def team_instructions(%State{name: name}) do
    [
      "You are the sub-agent \"#{name}\" of another agent, working on the task it gave you. " <>
        "Do the task; your final message is your report back to it — make it complete and " <>
        "self-contained (facts, sources, what you changed, what is open), since it is all " <>
        "the other agent sees."
    ]
  end

  # the child's turn ended: its final message (or its failure) goes to the parent
  def report_to_parent(%State{parent: nil}, _status, _error), do: :ok

  def report_to_parent(%State{parent: parent, name: name} = state, status, error) do
    report =
      case status do
        "completed" -> last_answer(state) || "(no answer)"
        other -> "#{other}: #{error || "no details"}"
      end

    case Longx.Agent.whereis(parent) do
      nil -> :ok
      pid -> Kernel.send(pid, {:agent_message, name, report})
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
