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
      child =
        member(state, name, pid, :working, Keyword.get(opts, :role), summary(task))

      state = %{state | children: Map.put(state.children, child_id, child)}
      {:ok, child_id, activity(state, child_id, name, "started")}
    end
  end

  # a team member: its process when alive (monitored), what it is and what
  # it was given; `n` keeps the order the team was made in
  defp member(%State{children: children}, name, pid, status, role, task) do
    %{
      name: name,
      pid: pid,
      ref: if(pid, do: Process.monitor(pid)),
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
            :keep -> %{child | status: status}
            nil -> %{child | status: status, pid: nil, ref: nil}
            pid -> %{child | status: status, pid: pid, ref: Process.monitor(pid)}
          end

        %{state | children: Map.put(children, child_id, child)}
    end
  end

  # a child spoken to again: alive again (revived by `Longx.Agent.send/3`)
  # under a new pid — monitored anew — and working
  def rewatch(%State{children: children} = state, child_id) do
    case {Map.get(children, child_id), Longx.Agent.whereis(child_id)} do
      {nil, _} ->
        state

      {%{pid: pid}, pid} when is_pid(pid) ->
        mark(state, child_id, :working)

      {%{ref: ref}, new_pid} ->
        if ref, do: Process.demonitor(ref, [:flush])
        mark(state, child_id, :working, new_pid)
    end
  end

  def forget(%State{children: children} = state, child_id) do
    case Map.pop(children, child_id) do
      {nil, _} ->
        state

      {%{ref: ref}, rest} ->
        if ref, do: Process.demonitor(ref, [:flush])
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

  defp running?(child_id) do
    match?({:running, _}, Longx.Agent.status(child_id))
  catch
    :exit, _ -> false
  end

  # the parent's other children, from the specs (an ETS read, never a call
  # to the parent — it may be calling this agent at the same time)
  def siblings(%State{parent: nil}), do: []

  def siblings(%State{parent: parent, thread_id: id}) do
    for {child_id, opts} <- Longx.Agent.Kernel.Specs.children_of(parent), child_id != id do
      %{
        id: child_id,
        name: Keyword.get(opts, :name),
        role: Keyword.get(opts, :role),
        task: Keyword.get(opts, :task)
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
             # no model given: the role's own, else the default (not the parent's)
             model: Keyword.get(opts, :model),
             effort: Keyword.get(opts, :effort),
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

  def team_instructions(%State{name: name}) do
    [
      "You are the sub-agent \"#{name}\" of another agent, working on the task it gave you. " <>
        "Do the task; your final message is your report back to it — make it complete and " <>
        "self-contained (facts, sources, what you changed, what is open), since it is all " <>
        "the other agent sees."
    ]
  end

  # the child's turn ended: its final message (or its failure) goes to whoever
  # started the turn — a teammate that asked (`reply_to`), else the parent
  def report_to_parent(%State{parent: nil, reply_to: nil}, _status, _error), do: :ok

  def report_to_parent(
        %State{parent: parent, reply_to: reply_to, name: name} = state,
        status,
        error
      ) do
    report =
      case status do
        "completed" -> last_answer(state) || "(no answer)"
        other -> "#{other}: #{error || "no details"}"
      end

    target = reply_to || parent

    case Longx.Agent.whereis(target) do
      pid when is_pid(pid) ->
        Kernel.send(pid, {:agent_message, name, report})

      nil ->
        # the asker left idle meanwhile: bring it back with the report — from a
        # task, since a GenServer.call from inside this callback could meet the
        # asker calling us (its stop asks children first) and wait 15 s for nothing
        Task.Supervisor.start_child(Longx.Agent.TaskSupervisor, fn ->
          Longx.Agent.send(target, report, from: name)
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
