defmodule Longx.Agent do
  @moduledoc """
  The agent kernel: one process per thread, the loop as OTP recursion.

  The process holds the state and the mailbox and never blocks: a step
  runs the thread's pipeline (`Longx.Agent.Pipeline`, pure — the prompt,
  the tools, the request), the model call streams from a task
  (`Longx.Agent.Model`) as messages, tool calls run as tasks and answer as
  messages, and `handle_continue(:step)` recurses until the model answers
  without calling a tool. A message while a turn runs is a *steer*: shown
  at once, handed to the model at the next step (and a step is added when
  the model stopped before seeing it). Interrupt kills the tasks — a tool's
  shim tree dies with its task — and ends the turn.

  Everything the person sees is the codex event vocabulary
  (`turn/started`, `item/started`, `item/agentMessage/delta`,
  `item/completed`, `thread/tokenUsage/updated`, `turn/completed`, …) fed
  to `Longx.Agent.ThreadState`, so the channel, the store and the whole
  React side are the same for both engines. The history is
  `Longx.Agent.Transcript`: a restart reloads it, replays the view and
  continues; nothing else remembers the conversation.

  No sandbox, no approvals: commands run on the machine as the person.
  """

  use GenServer

  require Logger

  alias Longx.Agent.{Step, Tool, Transcript}
  alias Longx.Agent.Kernel.{Asks, Calls, Compaction, Goal, State, Stream, Team, UI}
  alias Longx.Agent.ThreadState
  import Longx.Agent.Kernel.State

  @registry Longx.Agent.Registry
  @supervisor Longx.Agent.Supervisor
  @tasks Longx.Agent.TaskSupervisor

  @interrupted "[interrupted]"

  # a turn-end plug may continue a turn this many times before it ends anyway
  @max_continues 20
  # and no turn runs more model steps than this (`config :longx, Longx.Agent,
  # max_steps:`): a response plug re-adding a call for ever, a model looping
  @default_max_steps 500

  ## API

  @doc """
  Starts the thread's agent (or finds it): `thread_id:` (the ThreadState /
  channel id), `cwd:`, `project_id:`, `model:` / `effort:` (the person's
  choice for the next turn), `pipeline:` (a `Longx.Agent.Pipeline` module;
  `config :longx, Longx.Agent, pipeline:` then the default).
  """
  @spec ensure(keyword) :: {:ok, pid} | {:error, term}
  def ensure(opts) do
    Longx.Agent.Kernel.Specs.put(Keyword.fetch!(opts, :thread_id), opts)

    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, opts}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  @doc "The agent, started again from what it was started with if it left (idle, crashed)."
  @spec ensure_alive(String.t()) :: {:ok, pid} | {:error, :unknown}
  def ensure_alive(thread_id) do
    case {whereis(thread_id), Longx.Agent.Kernel.Specs.get(thread_id)} do
      {pid, _} when is_pid(pid) -> {:ok, pid}
      {nil, nil} -> {:error, :unknown}
      {nil, opts} -> ensure(opts)
    end
  end

  @doc """
  Starts a child agent named `name` on `task` — another process, the same
  loop — and remembers it under the parent; the child's final answer comes
  back into the parent's mailbox (`send/3` with `from:`) when its turn
  ends. Options: `model:`, `effort:`, `cwd:`, `pipeline:` (the parent's by
  default). `{:ok, child_thread_id}`.
  """
  @spec spawn(String.t(), String.t(), String.t(), keyword) :: {:ok, String.t()} | {:error, term}
  def spawn(parent_id, name, task, opts \\ []),
    do: GenServer.call(via(parent_id), {:spawn, name, task, opts})

  @doc "A card for the person from a tool (`Context.present/2`): shown on the thread, never model input."
  @spec present(String.t(), map) :: :ok
  def present(thread_id, tree) when is_map(tree),
    do: GenServer.cast(via(thread_id), {:present, tree})

  @doc "Notes that the parent spoke to a child (the child's row in the parent's view shows it)."
  @spec interacted(String.t(), String.t()) :: :ok
  def interacted(parent_id, child_id), do: GenServer.cast(via(parent_id), {:interacted, child_id})

  @doc false
  # a tool (in its task) asks the person; the reply comes when they answer
  def ask(thread_id, request), do: GenServer.call(via(thread_id), {:ask, request}, :infinity)

  @doc "The person's answer to an open ask (`Context.ask/2`); `{:error, :unknown}` when none waits."
  @spec respond(String.t(), String.t(), map) :: :ok | {:error, :unknown}
  def respond(thread_id, request_id, answer) when is_map(answer) do
    case whereis(thread_id) do
      nil -> {:error, :unknown}
      _pid -> GenServer.call(via(thread_id), {:respond, request_id, answer})
    end
  end

  @doc "Who spawned the agent, its name, its phase and its children."
  @spec info(String.t()) :: map
  def info(thread_id), do: GenServer.call(via(thread_id), :info)

  @doc """
  The agent's team, in the order it was made: every agent it spawned, with
  `status` `"working"` / `"done"` / `"failed"` — a finished one stays a
  member (its transcript is kept; `send/3` continues it) until
  `forget_child/2`.
  """
  @spec children(String.t()) :: [
          %{
            id: String.t(),
            name: String.t(),
            status: String.t(),
            role: String.t() | nil,
            task: String.t() | nil
          }
        ]
  def children(thread_id), do: GenServer.call(via(thread_id), :children)

  @doc "Takes a child out of the parent's team (`close_agent`); stopping it is the caller's."
  @spec forget_child(String.t(), String.t()) :: :ok
  def forget_child(parent_id, child_id),
    do: GenServer.call(via(parent_id), {:forget_child, child_id})

  @spec whereis(String.t()) :: pid | nil
  def whereis(thread_id), do: GenServer.whereis(via(thread_id))

  @spec stop(String.t()) :: :ok
  def stop(thread_id) do
    case whereis(thread_id) do
      nil ->
        :ok

      pid ->
        # the children first, and to the end: a child left to notice the parent's
        # death would still be closing its turn (transcript writes) after this
        # returned. Then a normal stop: the callback in flight finishes first —
        # the supervisor's kill left SQLite's connection mid-transaction
        try do
          for %{id: child} <- GenServer.call(pid, :children, 5_000), do: stop(child)
          GenServer.stop(pid, :normal, 15_000)
        catch
          :exit, _ -> :ok
        end
    end
  end

  @doc """
  A user message: a new turn when the thread is idle (`turn_id:` names it,
  else one is made), a steer into the running one otherwise. `model:` /
  `effort:` set the level for this and later turns; `images:` are data
  urls. From another agent: `from:` (its name — the text is shown and sent
  as `[agent name] …`) and `reply_to:` (its thread id — the answer of the
  turn this starts goes to it instead of the parent). Answers
  `{:ok, %{turn_id, steered}}`.
  """
  @spec send(String.t(), String.t(), keyword) :: {:ok, %{turn_id: String.t(), steered: boolean}}
  def send(thread_id, text, opts \\ []) do
    # an agent that left comes back for a message (from the person or another agent)
    with {:ok, _pid} <- ensure_alive(thread_id) do
      GenServer.call(via(thread_id), {:send, text, opts})
    end
  end

  @doc "Stops the running turn (its items end as they are)."
  @spec interrupt(String.t()) :: :ok | {:error, :not_running}
  def interrupt(thread_id), do: GenServer.call(via(thread_id), :interrupt, 15_000)

  @doc "Stops the running turn and drops it from the transcript and the view (`thread/reverted`)."
  @spec retract(String.t(), String.t()) :: :ok | {:error, :not_running}
  def retract(thread_id, turn_id), do: GenServer.call(via(thread_id), {:retract, turn_id}, 15_000)

  @doc """
  Folds the context (`/compact`): at once when the thread is idle, before
  the next step when a turn runs. Nothing to fold is fine.
  """
  @spec compact(String.t()) :: :ok
  def compact(thread_id), do: GenServer.call(via(thread_id), :compact)

  @spec status(String.t()) :: :idle | {:running, String.t()}
  def status(thread_id), do: GenServer.call(via(thread_id), :status)

  @doc """
  Sets or changes the thread's goal (`"objective"`, `"status"`,
  `"tokenBudget"`; keys absent stay) and shows it (`thread/goal/updated`).
  A goal `active` makes the Goal plug continue turns until it is complete.
  """
  @spec set_goal(String.t(), map) :: {:ok, map} | {:error, term}
  def set_goal(thread_id, attrs) when is_map(attrs) do
    with {:ok, _pid} <- ensure_alive(thread_id),
         do: GenServer.call(via(thread_id), {:set_goal, attrs})
  end

  @spec get_goal(String.t()) :: {:ok, map | nil} | {:error, term}
  def get_goal(thread_id) do
    with {:ok, _pid} <- ensure_alive(thread_id), do: GenServer.call(via(thread_id), :get_goal)
  end

  @doc "Drops the goal (`thread/goal/cleared`); whether there was one."
  @spec clear_goal(String.t()) :: {:ok, boolean} | {:error, term}
  def clear_goal(thread_id) do
    with {:ok, _pid} <- ensure_alive(thread_id), do: GenServer.call(via(thread_id), :clear_goal)
  end

  def start_link(opts) do
    thread_id = Keyword.fetch!(opts, :thread_id)
    GenServer.start_link(__MODULE__, opts, name: via(thread_id))
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :thread_id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  defp via(thread_id), do: {:via, Registry, {@registry, thread_id}}

  ## Server

  @impl true
  def init(opts) do
    thread_id = Keyword.fetch!(opts, :thread_id)
    items = Transcript.items!(thread_id)

    state = %State{
      thread_id: thread_id,
      project_id: Keyword.get(opts, :project_id),
      cwd: Keyword.get(opts, :cwd) || File.cwd!(),
      model: Keyword.get(opts, :model),
      effort: Keyword.get(opts, :effort),
      pipeline: Keyword.get(opts, :pipeline) || configured_pipeline(),
      parent: Keyword.get(opts, :parent),
      name: Keyword.get(opts, :name),
      role: Keyword.get(opts, :role),
      depth: Keyword.get(opts, :depth, 0),
      path: Keyword.get(opts, :path) || "/root",
      spawner: Keyword.get(opts, :spawner),
      settings: Keyword.get(opts, :settings, fn -> nil end),
      models: Keyword.get(opts, :models, fn -> nil end),
      idle_ms: Keyword.get(opts, :idle_ms, configured_idle_ms()),
      last_active: System.monotonic_time(:millisecond),
      trust: Keyword.get(opts, :trust, fn -> false end),
      web_search: Keyword.get(opts, :web_search, true),
      seq: items |> Enum.map(& &1.seq) |> Enum.max(fn -> 0 end),
      transcript: Transcript.input(items),
      # the goal outlives the process in the view
      goal: ThreadState.Store.meta(thread_id).goal
    }

    {:ok, _} = ThreadState.ensure(thread_id)
    replay(state, items)
    # the team it spawned before it left, from the specs
    state = Team.restore_children(state)
    # a child goes when its parent goes
    with parent when is_binary(parent) <- state.parent, pid when is_pid(pid) <- whereis(parent) do
      Process.monitor(pid)
    end

    {:ok, schedule_idle(state)}
  end

  @default_idle_ms 30 * 60_000

  defp configured_idle_ms,
    do: :longx |> Application.get_env(__MODULE__, []) |> Keyword.get(:idle_ms, @default_idle_ms)

  defp schedule_idle(%State{idle_ms: nil} = state), do: state

  defp schedule_idle(%State{idle_ms: ms} = state) do
    Process.send_after(self(), :idle_check, ms)
    state
  end

  # nil = the loader (the shipped, the person's and the project's descriptions)
  defp configured_pipeline,
    do: :longx |> Application.get_env(__MODULE__, []) |> Keyword.get(:pipeline)

  # a view nobody built yet (a boot, a store wiped) is rebuilt from the log,
  # synchronously — the way a codex resume seeds it (`thread/read` shape)
  defp replay(%State{thread_id: id, cwd: cwd}, items) do
    if ThreadState.snapshot(id).thread == nil do
      turns =
        items
        |> Enum.filter(&match?(%{ui: %{}}, &1))
        |> Enum.chunk_by(& &1.turn_id)
        |> Enum.map(fn [%{turn_id: turn_id} | _] = chunk ->
          %{"id" => turn_id, "status" => "completed", "items" => Enum.map(chunk, & &1.ui)}
        end)

      ThreadState.backfill(id, %{"thread" => %{"id" => id, "cwd" => cwd, "turns" => turns}})
    end

    :ok
  end

  @impl true
  def handle_call({:send, text, opts}, _from, %State{phase: :idle} = state) do
    {turn_id, state} = start_turn(state, text, opts)
    {:reply, {:ok, %{turn_id: turn_id, steered: false}}, state, {:continue, :step}}
  end

  def handle_call({:send, text, opts}, _from, %State{turn_id: turn_id} = state) do
    {:reply, {:ok, %{turn_id: turn_id, steered: true}}, queue_steer(state, text, opts)}
  end

  def handle_call({:spawn, name, task, opts}, _from, state) do
    case Team.spawn_child(state, name, task, opts) do
      {:ok, child_id, state} -> {:reply, {:ok, child_id}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:info, _from, state) do
    {:reply,
     %{
       parent: state.parent,
       name: state.name,
       phase: state.phase,
       children: Team.children_list(state)
     }, state}
  end

  def handle_call(:children, _from, state), do: {:reply, Team.children_list(state), state}

  def handle_call({:forget_child, child_id}, _from, state),
    do: {:reply, :ok, Team.forget(state, child_id)}

  def handle_call({:ask, request}, from, %State{} = state) do
    id = "ask_" <> Ash.UUID.generate()

    callback =
      if request.callback? do
        Asks.register(id, state.thread_id)
        String.trim_trailing(Longx.System.public_url(), "/") <> "/callback/" <> id
      end

    url =
      case request.url do
        fun when is_function(fun, 1) -> fun.(callback)
        other -> other
      end

    params =
      %{
        "itemId" => request.item_id,
        "title" => request.title,
        "text" => request.text,
        "url" => url,
        "fields" =>
          Enum.map(request.fields, fn f ->
            %{"id" => to_string(f[:id] || f["id"]), "label" => f[:label] || f["label"] || ""}
            |> then(&if(f[:secret] || f["secret"], do: Map.put(&1, "secret", true), else: &1))
            # required unless said otherwise (a public OAuth2 client has no secret to type)
            |> then(
              &if(Map.get(f, :required, Map.get(f, "required", true)) == false,
                do: Map.put(&1, "required", false),
                else: &1
              )
            )
          end),
        "callbackUrl" => callback
      }
      |> then(&if(is_map(request[:spec]), do: Map.put(&1, "spec", request.spec), else: &1))
      |> then(&if(is_map(request[:meta]), do: Map.put(&1, "meta", request.meta), else: &1))

    ThreadState.put_request(state.thread_id, id, "longx/action/request", params)
    timer = request.timeout && Process.send_after(self(), {:ask_timeout, id}, request.timeout)
    ask = %{from: from, timer: timer, callback?: request.callback?}
    {:noreply, %{state | asks: Map.put(state.asks, id, ask)}}
  end

  def handle_call({:respond, id, answer}, _from, %State{asks: asks} = state) do
    case Map.pop(asks, id) do
      {nil, _} ->
        {:reply, {:error, :unknown}, state}

      {ask, rest} ->
        reply = if answer["cancelled"] == true, do: {:error, :cancelled}, else: {:ok, answer}
        Asks.settle_ask(state, id, ask, reply)
        {:reply, :ok, %{state | asks: rest}}
    end
  end

  def handle_call({:set_goal, attrs}, _from, state) do
    state = Goal.update_goal(touch(state), attrs)
    {:reply, {:ok, state.goal}, state}
  end

  def handle_call(:get_goal, _from, state), do: {:reply, {:ok, state.goal}, state}

  def handle_call(:clear_goal, _from, %State{goal: goal} = state) do
    if goal, do: emit(state, "thread/goal/cleared", %{})
    {:reply, {:ok, goal != nil}, %{state | goal: nil}}
  end

  def handle_call(:interrupt, _from, %State{phase: :idle} = state),
    do: {:reply, {:error, :not_running}, state}

  def handle_call(:interrupt, _from, state) do
    {:reply, :ok, state |> stop_work() |> end_turn("interrupted", nil)}
  end

  def handle_call({:retract, turn_id}, _from, %State{phase: phase, turn_id: turn_id} = state)
      when phase != :idle do
    state = stop_work(state, close_items: false)
    Transcript.truncate!(state.thread_id, turn_id)
    ThreadState.drop_turns(state.thread_id, [turn_id])

    remaining = state.thread_id |> Transcript.items!() |> Transcript.input()
    state = %{state | transcript: remaining, steers: []}
    {:reply, :ok, end_turn(state, "interrupted", nil)}
  end

  def handle_call({:retract, _turn_id}, _from, state), do: {:reply, {:error, :not_running}, state}

  def handle_call(:compact, _from, %State{phase: :idle, transcript: []} = state),
    do: {:reply, :ok, state}

  def handle_call(:compact, _from, %State{phase: :idle} = state),
    do: {:reply, :ok, Compaction.start_compaction(state, state.model)}

  def handle_call(:compact, _from, state), do: {:reply, :ok, %{state | compact_requested: true}}

  def handle_call(:status, _from, %State{phase: :idle} = state), do: {:reply, :idle, state}

  def handle_call(:status, _from, %State{turn_id: id} = state),
    do: {:reply, {:running, id}, state}

  @impl true
  def handle_cast({:present, tree}, state), do: {:noreply, Calls.present(state, tree)}

  # a child spoken to again (by this agent or a teammate): working again,
  # under whatever pid `send/3` revived it with
  def handle_cast({:interacted, child_id}, %State{children: children} = state) do
    case Map.get(children, child_id) do
      %{name: name} ->
        {:noreply, state |> Team.rewatch(child_id) |> Team.activity(child_id, name, "interacted")}

      nil ->
        {:noreply, state}
    end
  end

  # a new turn on an idle agent: from the person, or from another agent (`from:`)
  defp start_turn(%State{} = state, text, opts) do
    turn_id = Keyword.get(opts, :turn_id) || new_id("turn")
    {text, from} = attributed(text, opts)

    state =
      %{
        touch(state)
        | turn_id: turn_id,
          phase: :step,
          model: Keyword.get(opts, :model, state.model),
          effort: Keyword.get(opts, :effort, state.effort),
          reply_to: Keyword.get(opts, :reply_to),
          usage_total: %{},
          continues: 0,
          steps: 0,
          turn_state: %{}
      }
      |> tap(&emit(&1, "turn/started", %{"turn" => %{"id" => turn_id, "status" => "inProgress"}}))
      |> Team.with_activity(Keyword.get(opts, :activity))
      |> append_user(text, Keyword.get(opts, :images, []), from)

    {turn_id, state}
  end

  # into the model's context at the next step, and shown then (until then
  # it is the client's queue, where it can still be taken back)
  defp queue_steer(%State{turn_id: turn_id} = state, text, opts) do
    images = Keyword.get(opts, :images, [])
    {text, from} = attributed(text, opts)
    ui = user_ui(new_id("item"), turn_id, text, images, from)
    %{touch(state) | steers: state.steers ++ [{user_input(text, images), ui}]}
  end

  # a message from another agent is a user message that says who: the
  # Responses API has no agent role every provider reads
  defp attributed(text, opts) do
    case Keyword.get(opts, :from) do
      nil -> {text, nil}
      from -> {"[agent #{from}] " <> text, from}
    end
  end

  # a message arriving on its own (a child's report, its crash): a steer
  # while a turn runs, a turn of its own when idle
  defp deliver(%State{phase: :idle} = state, text, from, activity) do
    {_turn_id, state} = start_turn(state, text, from: from, activity: activity)
    {:noreply, state, {:continue, :step}}
  end

  defp deliver(state, text, from, activity),
    do: {:noreply, state |> Team.with_activity(activity) |> queue_steer(text, from: from)}

  # what the parent's view shows of a child: codex's subAgentActivity item
  # (the client folds them into one row with the child's conversation), kept
  # in the transcript as a UI-only item so a rebuilt view has it
  ## The loop

  @impl true
  def handle_continue(:step, %State{steps: steps} = state) do
    if steps >= max_steps() do
      {:noreply, end_turn(state, "failed", "the turn ran #{steps} steps; stopped (max_steps)")}
    else
      state = fold_steers(%{state | steps: steps + 1})
      run_request_phase(state)
    end
  end

  defp max_steps,
    do:
      :longx |> Application.get_env(__MODULE__, []) |> Keyword.get(:max_steps, @default_max_steps)

  defp run_request_phase(%State{} = state, opts \\ []) do
    case run_pipeline(state.pipeline, build_step(state, :request)) do
      {:ok, %Step{} = step} ->
        run_request_phase_with(take_effects(state, step), {:ok, step}, opts)

      result ->
        run_request_phase_with(state, result, opts)
    end
  end

  defp run_request_phase_with(%State{} = state, result, opts) do
    case result do
      {:ok, %Step{halted: true, reason: reason}} ->
        {:noreply, end_turn(state, "failed", "pipeline halted: #{describe(reason)}")}

      {:ok, %Step{effects: effects, model: model} = step} ->
        # a compact effect folds the context first (unless this is the retry after a failed fold)
        wanted? = Enum.any?(effects, &match?({:compact, _}, &1))

        if wanted? and not Keyword.get(opts, :skip_compact, false) and state.transcript != [],
          do: {:noreply, Compaction.start_compaction(state, model)},
          else: start_model(state, step)

      {:error, message} ->
        {:noreply, end_turn(state, "failed", message)}
    end
  end

  defp start_model(state, %Step{request: nil}),
    do: {:noreply, end_turn(state, "failed", "the pipeline built no request")}

  defp start_model(state, %Step{request: request, model: model, tools: tools}) do
    ref = make_ref()

    task =
      Task.Supervisor.async_nolink(@tasks, Longx.Agent.Model, :run, [
        Longx.Agent.Model.prepare(request),
        self(),
        ref
      ])

    {:noreply,
     %{
       state
       | phase: :streaming,
         step_model: model || "longx",
         tools: tools,
         model_task: %{task: task, ref: ref},
         items: %{},
         calls: [],
         last_search: nil
     }}
  end

  defp build_step(%State{} = state, phase, extra \\ []) do
    Step.new(
      [
        thread_id: state.thread_id,
        turn_id: state.turn_id,
        project_id: state.project_id,
        cwd: state.cwd,
        model: state.model,
        effort: state.effort,
        transcript: state.transcript,
        phase: phase,
        usage: %{last: state.usage_last, total: state.usage_total},
        context_window: state.context_window,
        assigns: %{
          trust: state.trust,
          settings: state.settings,
          models_fun: state.models,
          web_search: state.web_search,
          context_overflow: state.context_overflow,
          compact_requested: state.compact_requested,
          parent: state.parent,
          name: state.name,
          role: state.role,
          depth: state.depth,
          children: Team.children_list(state),
          siblings: Team.siblings(state),
          goal: state.goal
        },
        state: state.turn_state,
        instructions: Team.team_instructions(state)
      ] ++ extra
    )
  end

  defp run_pipeline(nil, step), do: run_pipeline({:loaded, load_definition(step)}, step)

  defp run_pipeline({:loaded, loaded}, step) do
    # the description's model and level stand where the person chose none —
    # if Longx has that model; a slug nobody configured is a notice and the
    # default runs (a failed turn taught the agent nothing). The notices (a
    # file that failed to load, an old format) lead the prompt.
    models = (step.assigns[:models_fun] || fn -> nil end).()
    {model, effort, notices} = description_model(step, loaded, models)

    step = %{
      step
      | model: model,
        effort: effort,
        instructions: Enum.map(notices, &("⚠ " <> &1)) ++ step.instructions,
        assigns:
          Map.merge(step.assigns, %{
            agents: loaded.agents,
            allowed: loaded.allowed,
            models: models
          })
    }

    {:ok, Longx.Agent.Pipeline.run(step, loaded.plugs)}
  rescue
    e -> {:error, "pipeline failed: " <> Exception.message(e)}
  end

  defp run_pipeline(pipeline, step) when is_atom(pipeline) do
    {:ok, pipeline.run(step)}
  rescue
    e -> {:error, "pipeline failed: " <> Exception.message(e)}
  end

  defp description_model(%Step{model: chosen} = step, loaded, _models) when is_binary(chosen),
    do: {chosen, step.effort, loaded.notices}

  defp description_model(%Step{} = step, %{model: nil} = loaded, _models),
    do: {nil, step.effort, loaded.notices}

  defp description_model(%Step{} = step, %{model: slug} = loaded, models) do
    known = models && Enum.map(models, & &1.slug)

    if known == nil or slug in known do
      {slug, step.effort || loaded.effort, loaded.notices}
    else
      notice =
        "The agent description names model #{inspect(slug)}, which is not configured in Longx; " <>
          "running on the default model instead. Models you may name: " <>
          Enum.join(known, ", ") <> ". Fix the description (model \"<slug>\")."

      {nil, step.effort, loaded.notices ++ [notice]}
    end
  end

  defp load_definition(%Step{cwd: cwd, project_id: project_id, assigns: assigns}) do
    trusted? = (assigns[:trust] || fn -> false end).()

    Longx.Agent.Definition.Loader.load(cwd,
      tag: project_id || "adhoc",
      trusted: trusted?,
      agent: assigns[:role],
      settings: (assigns[:settings] || fn -> nil end).()
    )
  end

  # the model answered: the response phase may add calls of its own or halt
  defp response_phase(%State{} = state, calls) do
    step = build_step(state, :response, calls: Enum.map(calls, &call_summary/1))

    case run_pipeline(state.pipeline, step) do
      {:ok, %Step{halted: true, reason: reason}} ->
        {:halt, "pipeline halted: #{describe(reason)}"}

      {:ok, %Step{effects: effects} = step} ->
        extra =
          for {:call, name, args} <- effects do
            %{
              "type" => "function_call",
              "call_id" => new_id("longx"),
              "name" => name,
              "arguments" => Jason.encode!(args)
            }
          end

        {:ok, calls ++ extra, take_effects(state, step)}

      {:error, message} ->
        {:halt, message}
    end
  end

  # nothing left to do: the turn-end phase may continue instead
  defp turn_end_phase(%State{continues: continues} = state) when continues >= @max_continues,
    do: end_turn(state, "completed", nil)

  defp turn_end_phase(%State{} = state) do
    case run_pipeline(state.pipeline, build_step(state, :turn_end)) do
      {:ok, %Step{halted: true, reason: reason}} ->
        end_turn(state, "failed", "pipeline halted: #{describe(reason)}")

      {:ok, %Step{effects: effects} = step} ->
        state = take_effects(state, step)

        case Enum.find(effects, &match?({:continue, _}, &1)) do
          {:continue, text} ->
            state = %{state | continues: state.continues + 1, phase: :step, model_task: nil}
            state = append_user(state, text, [])
            Kernel.send(self(), :next_step)
            state

          nil ->
            end_turn(state, "completed", nil)
        end

      {:error, message} ->
        end_turn(state, "failed", message)
    end
  end

  # what every phase takes from the step it ran: `step.state`, and the
  # children the plugs asked for (a failure to start one is a message from it)
  defp take_effects(%State{} = state, %Step{state: st, effects: effects}) do
    Enum.reduce(effects, %{state | turn_state: st}, fn
      {:goal, attrs}, acc ->
        Goal.update_goal(acc, attrs)

      {:spawn, name, task, opts}, acc ->
        case Team.spawn_child(acc, name, task, opts) do
          {:ok, _id, acc} ->
            acc

          {:error, reason} ->
            queue_steer(acc, "could not be started: #{describe(reason)}", from: name)
        end

      _other, acc ->
        acc
    end)
  end

  defp call_summary(%{"call_id" => call_id, "name" => name} = call) do
    %{id: call["id"], call_id: call_id, name: name, arguments: Calls.arguments_of(call, nil)}
  end

  # the steers become user messages in the context, after the tool outputs
  defp fold_steers(%State{steers: []} = state), do: state

  defp fold_steers(%State{steers: steers} = state) do
    Enum.reduce(steers, %{state | steers: []}, fn {input, ui}, acc ->
      emit(acc, "item/started", %{"item" => ui, "turnId" => acc.turn_id})
      append(acc, :user_message, input, ui)
    end)
  end

  ## Model events

  # the chain moved on to its next model (a quota gone, a key refused, an
  # upstream down): the person hears it the way codex's reroute is heard
  @impl true
  def handle_info(
        {:model, ref, {:fallback, from, to, reason}},
        %State{model_task: %{ref: ref}} = state
      ) do
    emit(state, "model/rerouted", %{"fromModel" => from, "toModel" => to, "reason" => reason})
    {:noreply, state}
  end

  def handle_info(
        {:model, ref, event},
        %State{phase: :compacting, model_task: %{ref: ref}} = state
      ),
      do: compaction_event(event, state)

  def handle_info(
        {:model, ref, event},
        %State{phase: :streaming, model_task: %{ref: ref}} = state
      ),
      do: model_event(event, state)

  def handle_info({:model, _ref, _event}, state), do: {:noreply, state}

  # a task's reply (async_nolink) — the tool tasks carry their outcome here
  def handle_info({ref, outcome}, %State{tasks: tasks} = state) when is_map_key(tasks, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, Calls.finish_call(state, ref, outcome)}
  end

  def handle_info({ref, _reply}, %State{model_task: %{task: %Task{ref: ref}}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %State{tasks: tasks} = state)
      when is_map_key(tasks, ref) do
    {:noreply, Calls.finish_call(state, ref, {:error, "the tool crashed: #{describe(reason)}"})}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %State{phase: phase, model_task: %{task: %Task{ref: ref}}} = state
      )
      when phase in [:streaming, :compacting] do
    {:noreply, end_turn(state, "failed", "the model call crashed: #{describe(reason)}")}
  end

  def handle_info({:tool_output, item_id, text}, state) do
    case Enum.find(state.tasks, fn {_ref, t} -> t.item_id == item_id end) do
      {ref, %{tool: %Tool{show: show}} = task} ->
        emit(state, UI.delta_method(show), %{
          "itemId" => item_id,
          "delta" => text,
          "turnId" => state.turn_id
        })

        {:noreply,
         %{state | tasks: Map.put(state.tasks, ref, %{task | output: [task.output, text]})}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:tool_timeout, ref}, %State{tasks: tasks} = state)
      when is_map_key(tasks, ref) do
    %{tool: tool} = tasks[ref]
    Task.Supervisor.terminate_child(@tasks, tasks[ref].pid)

    {:noreply,
     Calls.finish_call(state, ref, {:error, "the tool did not finish within #{tool.timeout} ms"})}
  end

  def handle_info(:next_step, %State{phase: :step} = state),
    do: {:noreply, state, {:continue, :step}}

  # another agent (a child reporting back) speaks: into the mailbox, like the person
  def handle_info({:agent_message, from, text}, state) do
    case Enum.find(state.children, fn {_id, c} -> c.name == from end) do
      {id, _} -> deliver(Team.mark(state, id, :done), text, from, {id, from, "completed"})
      nil -> deliver(state, text, from, nil)
    end
  end

  # a child's process left: idle or stopped (`:normal`) it stays a member —
  # its transcript is kept and a message brings it back —; a crash is news
  # for the model, the child a failed member it may ask again or close. The
  # parent gone takes this agent along.
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Enum.find(state.children, fn {_id, c} -> c.ref == ref end) do
      {id, %{name: name, status: status}} ->
        # :noproc — a monitor set on a process that had just left (a revived
        # parent watching a child that went idle meanwhile) — is a normal leave
        if reason in [:normal, :shutdown, :noproc] or match?({:shutdown, _}, reason) do
          {:noreply, Team.mark(state, id, if(status == :working, do: :done, else: status), nil)}
        else
          state = Team.mark(state, id, :failed, nil)
          deliver(state, "exited: #{exit_text(reason)}", name, {id, name, "interrupted"})
        end

      nil ->
        # the parent's process left: idle (it comes back for this agent's
        # report) or crashed (likewise, from its spec) — the child goes on;
        # only a parent forgotten for good (its spec deleted: closed, the
        # thread deleted) takes it along
        if state.parent && whereis(state.parent) in [nil, pid] &&
             Longx.Agent.Kernel.Specs.get(state.parent) == nil,
           do: {:stop, :normal, stop_turn(state)},
           else: {:noreply, state}
    end
  end

  def handle_info({:ask_timeout, id}, %State{asks: asks} = state) do
    case Map.pop(asks, id) do
      {nil, _} ->
        {:noreply, state}

      {ask, rest} ->
        Asks.settle_ask(state, id, ask, {:error, :timeout})
        {:noreply, %{state | asks: rest}}
    end
  end

  # idle for long enough: leave; a message brings the agent back (Specs)
  def handle_info(:idle_check, %State{phase: :idle, idle_ms: ms, last_active: at} = state)
      when is_integer(ms) do
    if System.monotonic_time(:millisecond) - at >= ms,
      do: {:stop, :normal, state},
      else: {:noreply, schedule_idle(state)}
  end

  def handle_info(:idle_check, state), do: {:noreply, schedule_idle(state)}

  def handle_info(_other, state), do: {:noreply, state}

  defp exit_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp exit_text(reason), do: describe(reason)

  defp stop_turn(%State{phase: :idle} = state), do: state
  defp stop_turn(state), do: state |> stop_work() |> end_turn("interrupted", nil)

  defp model_event({:completed, response, %{context_window: window}}, state) do
    state = state |> Stream.close_open_items() |> Stream.record_usage(response["usage"], window)

    case response_phase(state, state.calls) do
      {:halt, message} ->
        {:noreply, end_turn(state, "failed", message)}

      {:ok, [], state} when state.steers == [] ->
        {:noreply, turn_end_phase(%{state | model_task: nil})}

      {:ok, [], state} ->
        # the model stopped before the steer reached it: one more step
        {:noreply, %{state | phase: :step, model_task: nil}, {:continue, :step}}

      {:ok, calls, state} ->
        {:noreply,
         Calls.dispatch(%{state | phase: :dispatching, model_task: nil, calls: []}, calls)}
    end
  end

  defp model_event({:failed, message}, state) do
    # the provider refused the request for its length: fold and try once more
    if Compaction.overflow?(message) and not state.context_overflow do
      Logger.info("agent #{state.thread_id}: context overflow, compacting: #{message}")

      %{Stream.close_open_items(state) | context_overflow: true, model_task: nil, phase: :step}
      |> run_request_phase()
    else
      {:noreply, state |> Stream.close_open_items() |> end_turn("failed", message)}
    end
  end

  # what the stream says while it runs: items opened, deltas shown, items
  # closed into the transcript, the model's calls collected
  defp model_event(event, state), do: {:noreply, Stream.fold(state, event)}

  defp compaction_event({:text_delta, _id, delta}, %State{compacting: c} = state),
    do: {:noreply, %{state | compacting: %{c | text: c.text <> delta}}}

  defp compaction_event(
         {:item_done, %{"type" => "message"} = item},
         %State{compacting: c} = state
       ) do
    text = message_text(item)
    {:noreply, %{state | compacting: %{c | text: if(text == "", do: c.text, else: text)}}}
  end

  defp compaction_event({:completed, _response, _meta}, %State{compacting: c} = state) do
    state = Compaction.fold_summary(state, c)

    if c.was_running,
      do: run_request_phase(%{state | phase: :step}),
      else: {:noreply, %{state | phase: :idle}}
  end

  defp compaction_event(
         {:failed, message},
         %State{compacting: c, context_overflow: overflow?} = state
       ) do
    Logger.warning("agent #{state.thread_id}: compaction failed: #{message}")
    state = %{state | compacting: nil, model_task: nil, compact_requested: false}

    cond do
      not c.was_running ->
        {:noreply, %{state | phase: :idle}}

      overflow? ->
        {:noreply,
         end_turn(state, "failed", "context too long and the compaction failed: #{message}")}

      true ->
        run_request_phase(%{state | phase: :step}, skip_compact: true)
    end
  end

  defp compaction_event(_event, state), do: {:noreply, state}

  ## Turn end

  defp end_turn(%State{} = state, status, error) do
    turn = %{"id" => state.turn_id, "status" => status}
    turn = if error, do: Map.put(turn, "error", %{"message" => error}), else: turn
    emit(state, "turn/completed", %{"turn" => turn})
    Team.report_to_parent(state, status, error)
    state = Asks.cancel_asks(state)

    state = touch(schedule_idle(state))

    %{
      state
      | phase: :idle,
        turn_id: nil,
        reply_to: nil,
        model_task: nil,
        items: %{},
        calls: [],
        tasks: %{},
        steers: [],
        compacting: nil,
        context_overflow: false,
        compact_requested: false,
        pending_images: []
    }
  end

  # kills the model task and the tool tasks; the commands die with their
  # tasks (the shim kills the tree when its owner goes)
  defp stop_work(%State{} = state, opts \\ []) do
    if state.model_task, do: Task.shutdown(state.model_task.task, :brutal_kill)

    state =
      Enum.reduce(state.tasks, state, fn {ref, entry}, acc ->
        if entry.timer, do: Process.cancel_timer(entry.timer)
        Process.demonitor(ref, [:flush])
        Task.Supervisor.terminate_child(@tasks, entry.pid)

        if Keyword.get(opts, :close_items, true),
          do: %{
            Calls.finish_call(%{acc | phase: :interrupted}, ref, {:error, @interrupted})
            | phase: acc.phase
          },
          else: %{acc | tasks: Map.delete(acc.tasks, ref)}
      end)

    if Keyword.get(opts, :close_items, true),
      do: Stream.close_open_items(state),
      else: %{state | items: %{}}
  end
end
