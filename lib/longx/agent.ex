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
  to `Longx.Codex.ThreadState`, so the channel, the store and the whole
  React side are the same for both engines. The history is
  `Longx.Agent.Transcript`: a restart reloads it, replays the view and
  continues; nothing else remembers the conversation.

  No sandbox, no approvals: commands run on the machine as the person.
  """

  use GenServer

  require Logger

  alias Longx.Agent.{Context, Step, Tool, Transcript}
  alias Longx.Codex.ThreadState

  @registry Longx.Agent.Registry
  @supervisor Longx.Agent.Supervisor
  @tasks Longx.Agent.TaskSupervisor

  @interrupted "[interrupted]"

  defmodule State do
    @moduledoc false
    defstruct thread_id: nil,
              project_id: nil,
              cwd: nil,
              model: nil,
              effort: nil,
              # a pipeline module (tests) or nil: the loader's layered description
              pipeline: nil,
              # whether the project's own .longx/ may be loaded (read per turn)
              trust: nil,
              # the thread's 联网搜索 switch (a plug reads it from the step's assigns)
              web_search: true,
              # the last web search of the step: citations in the message land on it
              last_search: nil,
              seq: 0,
              # Responses input items, oldest first (the model's context)
              transcript: [],
              phase: :idle,
              turn_id: nil,
              # what the step ran with (a plug may pick another model)
              step_model: nil,
              model_task: nil,
              # the step's tools by name, for the calls the model makes
              tools: %{},
              # model item id → %{ui: our item id, kind, text | summary, ...}
              items: %{},
              # function calls of the current response, in order
              calls: [],
              # task ref → %{call, item_id, tool, started, output, timer}
              tasks: %{},
              steers: [],
              usage_total: %{},
              usage_last: nil,
              context_window: nil,
              # continuations a turn-end plug asked for in this turn (capped)
              continues: 0,
              # model steps in this turn (capped)
              steps: 0,
              # a compaction in flight (phase :compacting): the summary text so far
              compacting: nil,
              # the provider refused the last request for its length: compact, retry once
              context_overflow: false,
              # a tool (new_context_window) or the person (/compact) asked for one
              compact_requested: false,
              # images tools attached in this step (view_image), added after its outputs
              pending_images: []
  end

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
    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, opts}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  @spec whereis(String.t()) :: pid | nil
  def whereis(thread_id), do: GenServer.whereis(via(thread_id))

  @spec stop(String.t()) :: :ok
  def stop(thread_id) do
    case whereis(thread_id) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(@supervisor, pid)
    end
  end

  @doc """
  A user message: a new turn when the thread is idle (`turn_id:` names it,
  else one is made), a steer into the running one otherwise. `model:` /
  `effort:` set the level for this and later turns; `images:` are data
  urls. Answers `{:ok, %{turn_id, steered}}`.
  """
  @spec send(String.t(), String.t(), keyword) :: {:ok, %{turn_id: String.t(), steered: boolean}}
  def send(thread_id, text, opts \\ []), do: GenServer.call(via(thread_id), {:send, text, opts})

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

  def start_link(opts) do
    thread_id = Keyword.fetch!(opts, :thread_id)
    GenServer.start_link(__MODULE__, opts, name: via(thread_id))
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :thread_id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
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
      trust: Keyword.get(opts, :trust, fn -> false end),
      web_search: Keyword.get(opts, :web_search, true),
      seq: items |> Enum.map(& &1.seq) |> Enum.max(fn -> 0 end),
      transcript: Transcript.input(items)
    }

    {:ok, _} = ThreadState.ensure(thread_id)
    replay(state, items)
    {:ok, state}
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
    turn_id = Keyword.get(opts, :turn_id) || new_id("turn")

    state =
      %State{
        state
        | turn_id: turn_id,
          phase: :step,
          model: Keyword.get(opts, :model, state.model),
          effort: Keyword.get(opts, :effort, state.effort),
          usage_total: %{},
          continues: 0,
          steps: 0
      }
      |> tap(&emit(&1, "turn/started", %{"turn" => %{"id" => turn_id, "status" => "inProgress"}}))
      |> append_user(text, Keyword.get(opts, :images, []))

    {:reply, {:ok, %{turn_id: turn_id, steered: false}}, state, {:continue, :step}}
  end

  def handle_call({:send, text, opts}, _from, %State{turn_id: turn_id} = state) do
    # shown now, in the model's context at the next step
    images = Keyword.get(opts, :images, [])
    ui = user_ui(new_id("item"), turn_id, text, images)
    emit(state, "item/started", %{"item" => ui, "turnId" => turn_id})
    emit(state, "item/completed", %{"item" => ui, "turnId" => turn_id})

    state = %{state | steers: state.steers ++ [{user_input(text, images), ui}]}
    {:reply, {:ok, %{turn_id: turn_id, steered: true}}, state}
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
    do: {:reply, :ok, start_compaction(state, state.model)}

  def handle_call(:compact, _from, state), do: {:reply, :ok, %{state | compact_requested: true}}

  def handle_call(:status, _from, %State{phase: :idle} = state), do: {:reply, :idle, state}

  def handle_call(:status, _from, %State{turn_id: id} = state),
    do: {:reply, {:running, id}, state}

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
      {:ok, %Step{halted: true, reason: reason}} ->
        {:noreply, end_turn(state, "failed", "pipeline halted: #{describe(reason)}")}

      {:ok, %Step{effects: effects, model: model} = step} ->
        # a compact effect folds the context first (unless this is the retry after a failed fold)
        wanted? = Enum.any?(effects, &match?({:compact, _}, &1))

        if wanted? and not Keyword.get(opts, :skip_compact, false) and state.transcript != [],
          do: {:noreply, start_compaction(state, model)},
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
      Task.Supervisor.async_nolink(@tasks, Longx.Agent.Model, :stream, [request, self(), ref])

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
          web_search: state.web_search,
          context_overflow: state.context_overflow,
          compact_requested: state.compact_requested
        }
      ] ++ extra
    )
  end

  defp run_pipeline(nil, step), do: run_pipeline({:loaded, load_definition(step)}, step)

  defp run_pipeline({:loaded, loaded}, step) do
    # the description's model and level stand where the person chose none;
    # its notices (a file that failed to load, an old format) lead the prompt
    step = %{
      step
      | model: step.model || loaded.model,
        effort: step.effort || (step.model == nil && loaded.effort) || nil,
        instructions: Enum.map(loaded.notices, &("⚠ " <> &1)) ++ step.instructions
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

  defp load_definition(%Step{cwd: cwd, project_id: project_id, assigns: assigns}) do
    trusted? = (assigns[:trust] || fn -> false end).()
    Longx.Agent.Loader.load(cwd, tag: project_id || "adhoc", trusted: trusted?)
  end

  # the model answered: the response phase may add calls of its own or halt
  defp response_phase(%State{} = state, calls) do
    step = build_step(state, :response, calls: Enum.map(calls, &call_summary/1))

    case run_pipeline(state.pipeline, step) do
      {:ok, %Step{halted: true, reason: reason}} ->
        {:halt, "pipeline halted: #{describe(reason)}"}

      {:ok, %Step{effects: effects}} ->
        extra =
          for {:call, name, args} <- effects do
            %{
              "type" => "function_call",
              "call_id" => new_id("longx"),
              "name" => name,
              "arguments" => Jason.encode!(args)
            }
          end

        {:ok, calls ++ extra}

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

      {:ok, %Step{effects: effects}} ->
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

  defp call_summary(%{"call_id" => call_id, "name" => name} = call) do
    %{id: call["id"], call_id: call_id, name: name, arguments: arguments_of(call, nil)}
  end

  # the steers become user messages in the context, after the tool outputs
  defp fold_steers(%State{steers: []} = state), do: state

  defp fold_steers(%State{steers: steers} = state) do
    Enum.reduce(steers, %{state | steers: []}, fn {input, ui}, acc ->
      append(acc, :user_message, input, ui)
    end)
  end

  ## Model events

  @impl true
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
    {:noreply, finish_call(state, ref, outcome)}
  end

  def handle_info({ref, _reply}, %State{model_task: %{task: %Task{ref: ref}}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %State{tasks: tasks} = state)
      when is_map_key(tasks, ref) do
    {:noreply, finish_call(state, ref, {:error, "the tool crashed: #{describe(reason)}"})}
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
        emit(state, delta_method(show), %{
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
     finish_call(state, ref, {:error, "the tool did not finish within #{tool.timeout} ms"})}
  end

  def handle_info(:next_step, %State{phase: :step} = state),
    do: {:noreply, state, {:continue, :step}}

  def handle_info(_other, state), do: {:noreply, state}

  defp model_event({:item_added, %{"id" => id, "type" => type}}, state)
       when type in ["message", "reasoning"] do
    ui_id = new_id("item")
    kind = if type == "message", do: :message, else: :reasoning

    ui =
      case kind do
        :message ->
          %{"id" => ui_id, "type" => "agentMessage", "turnId" => state.turn_id, "text" => ""}

        :reasoning ->
          %{
            "id" => ui_id,
            "type" => "reasoning",
            "turnId" => state.turn_id,
            "summary" => [],
            "content" => []
          }
      end

    emit(state, "item/started", %{"item" => ui, "turnId" => state.turn_id})

    {:noreply,
     put_item(state, id, %{ui: ui_id, kind: kind, text: "", summary: %{}, content: %{}})}
  end

  # a call the provider runs on its side (hosted web search): a webSearch row
  defp model_event({:item_added, %{"id" => id, "type" => "web_search_call"} = item}, state) do
    ui = hosted_search_ui(new_id("item"), state.turn_id, item, "inProgress")
    emit(state, "item/started", %{"item" => ui, "turnId" => state.turn_id})
    {:noreply, put_item(%{state | last_search: ui}, id, %{ui: ui["id"], kind: :hosted_call})}
  end

  defp model_event({:item_added, _item}, state), do: {:noreply, state}

  defp model_event({:text_delta, id, delta}, state) do
    with %{ui: ui_id} = item <- state.items[id] do
      emit(state, "item/agentMessage/delta", %{
        "itemId" => ui_id,
        "delta" => delta,
        "turnId" => state.turn_id
      })

      {:noreply, put_item(state, id, %{item | text: item.text <> delta})}
    else
      _ -> {:noreply, state}
    end
  end

  defp model_event({:reasoning_delta, id, index, delta}, state) do
    with %{ui: ui_id} = item <- state.items[id] do
      emit(state, "item/reasoning/summaryTextDelta", %{
        "itemId" => ui_id,
        "delta" => delta,
        "summaryIndex" => index,
        "turnId" => state.turn_id
      })

      {:noreply,
       put_item(state, id, %{
         item
         | summary: Map.update(item.summary, index, delta, &(&1 <> delta))
       })}
    else
      _ -> {:noreply, state}
    end
  end

  defp model_event({:reasoning_text_delta, id, index, delta}, state) do
    with %{ui: ui_id} = item <- state.items[id] do
      emit(state, "item/reasoning/textDelta", %{
        "itemId" => ui_id,
        "delta" => delta,
        "contentIndex" => index,
        "turnId" => state.turn_id
      })

      {:noreply,
       put_item(state, id, %{
         item
         | content: Map.update(item.content, index, delta, &(&1 <> delta))
       })}
    else
      _ -> {:noreply, state}
    end
  end

  defp model_event({:item_done, %{"type" => "message", "id" => id} = item}, state) do
    text = message_text(item)
    ui_id = ui_id(state, id)
    ui = %{"id" => ui_id, "type" => "agentMessage", "turnId" => state.turn_id, "text" => text}

    state =
      state
      |> cite(item)
      |> append(:agent_message, item, ui)
      |> drop_item(id)

    {:noreply, state}
  end

  defp model_event({:item_done, %{"type" => "reasoning", "id" => id} = item}, state) do
    ui = %{
      "id" => ui_id(state, id),
      "type" => "reasoning",
      "turnId" => state.turn_id,
      "summary" => texts(item["summary"]),
      "content" => texts(item["content"])
    }

    {:noreply, state |> append(:reasoning, item, ui) |> drop_item(id)}
  end

  defp model_event({:item_done, %{"type" => "web_search_call", "id" => id} = item}, state) do
    ui = hosted_search_ui(ui_id(state, id), state.turn_id, item, "completed")
    {:noreply, %{(state |> append(:hosted_call, item, ui) |> drop_item(id)) | last_search: ui}}
  end

  defp model_event({:item_done, %{"type" => type} = item}, state)
       when type in ["function_call", "custom_tool_call"],
       do: {:noreply, %{state | calls: state.calls ++ [item]}}

  defp model_event({:item_done, _item}, state), do: {:noreply, state}

  defp model_event({:completed, response, %{context_window: window}}, state) do
    state = state |> close_open_items() |> record_usage(response["usage"], window)

    case response_phase(state, state.calls) do
      {:halt, message} ->
        {:noreply, end_turn(state, "failed", message)}

      {:ok, []} when state.steers == [] ->
        {:noreply, turn_end_phase(%{state | model_task: nil})}

      {:ok, []} ->
        # the model stopped before the steer reached it: one more step
        {:noreply, %{state | phase: :step, model_task: nil}, {:continue, :step}}

      {:ok, calls} ->
        {:noreply, dispatch(%{state | phase: :dispatching, model_task: nil, calls: []}, calls)}
    end
  end

  defp model_event({:failed, message}, state) do
    # the provider refused the request for its length: fold and try once more
    if overflow?(message) and not state.context_overflow do
      Logger.info("agent #{state.thread_id}: context overflow, compacting: #{message}")

      %{close_open_items(state) | context_overflow: true, model_task: nil, phase: :step}
      |> run_request_phase()
    else
      {:noreply, state |> close_open_items() |> end_turn("failed", message)}
    end
  end

  # the sources a hosted search found arrive as the message's url_citation
  # annotations: they become the results of the last search row of the step
  defp cite(%State{last_search: %{} = search} = state, %{"content" => content})
       when is_list(content) do
    results =
      for %{"annotations" => annotations} <- content,
          %{"type" => "url_citation", "url" => url} = a <- List.wrap(annotations),
          uniq: true,
          do: %{"title" => a["title"] || url, "url" => url}

    if results == [] do
      state
    else
      ui = Map.put(search, "results", results)
      emit(state, "item/completed", %{"item" => ui, "turnId" => state.turn_id})
      %{state | last_search: nil}
    end
  end

  defp cite(state, _item), do: state

  defp hosted_search_ui(id, turn_id, %{"action" => action} = item, status) when is_map(action) do
    camel =
      case action["type"] do
        "open_page" -> "openPage"
        "find_in_page" -> "findInPage"
        other -> other || "search"
      end

    query =
      action["query"] || action["url"] || action["pattern"] ||
        action["queries"] |> List.wrap() |> Enum.join(" / ")

    %{
      "id" => id,
      "type" => "webSearch",
      "turnId" => turn_id,
      "query" => query,
      "action" => Map.put(action, "type", camel),
      "status" => item["status"] || status,
      "results" => []
    }
  end

  defp hosted_search_ui(id, turn_id, item, status),
    do: hosted_search_ui(id, turn_id, Map.put(item, "action", %{"type" => "search"}), status)

  @overflow ~r/context length|context_length|maximum context|too many tokens|token limit|exceeds .*context|prompt is too long|context window/i
  defp overflow?(message), do: is_binary(message) and Regex.match?(@overflow, message)

  ## Compaction (the `compact` effect, `/compact`, an overflow): codex's shape

  @compact_prompt File.read!(Path.join(:code.priv_dir(:longx), "agent/compact/prompt.md"))
  @summary_prefix String.trim(
                    File.read!(
                      Path.join(:code.priv_dir(:longx), "agent/compact/summary_prefix.md")
                    )
                  )

  # a summary of the context so far, streamed from a task like any model call
  defp start_compaction(%State{} = state, model) do
    ref = make_ref()

    request = %{
      "model" => model || "longx",
      "instructions" => @compact_prompt,
      "input" =>
        state.transcript ++
          [
            %{
              "type" => "message",
              "role" => "user",
              "content" => [%{"type" => "input_text", "text" => "Write the handoff summary now."}]
            }
          ],
      "tools" => [],
      "stream" => true,
      "store" => false,
      "client_metadata" => %{
        "thread_id" => state.thread_id,
        "turn_id" => state.turn_id,
        "x-codex-turn-metadata" => Jason.encode!(%{"request_kind" => "compaction"})
      }
    }

    task =
      Task.Supervisor.async_nolink(@tasks, Longx.Agent.Model, :stream, [request, self(), ref])

    %{
      state
      | phase: :compacting,
        model_task: %{task: task, ref: ref},
        compacting: %{text: "", model: model || "longx", was_running: state.turn_id != nil}
    }
  end

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
    turn_id = state.turn_id || last_turn_id(state)
    summary = String.trim(c.text)

    input = %{
      "type" => "message",
      "role" => "user",
      "content" => [%{"type" => "input_text", "text" => @summary_prefix <> "\n" <> summary}]
    }

    ui = %{"id" => new_id("item"), "type" => "contextCompaction", "turnId" => turn_id}
    seq = state.seq + 1

    Transcript.append!(%{
      thread_id: state.thread_id,
      turn_id: turn_id,
      seq: seq,
      kind: :compaction,
      input: input,
      ui: ui,
      model: c.model
    })

    emit(state, "item/completed", %{"item" => ui, "turnId" => turn_id})

    state = %{
      state
      | seq: seq,
        transcript: state.thread_id |> Transcript.items!() |> Transcript.input(),
        compacting: nil,
        model_task: nil,
        usage_last: nil,
        context_overflow: false,
        compact_requested: false
    }

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

  defp last_turn_id(%State{thread_id: id}) do
    case id |> Transcript.items!() |> List.last() do
      %{turn_id: turn_id} when is_binary(turn_id) -> turn_id
      _ -> "compaction"
    end
  end

  # a streamed item the model never closed (a failure, an interrupt) is
  # kept as far as it got — the person saw it, the model should too
  defp close_open_items(%State{items: items} = state) when map_size(items) == 0, do: state

  defp close_open_items(%State{items: items} = state) do
    Enum.reduce(items, state, fn
      {id, %{kind: :message, text: text, ui: ui_id}}, acc ->
        input = %{
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => text}]
        }

        ui = %{"id" => ui_id, "type" => "agentMessage", "turnId" => acc.turn_id, "text" => text}
        acc |> append(:agent_message, input, ui) |> drop_item(id)

      {id, %{kind: :reasoning, ui: ui_id, summary: summary, content: content}}, acc ->
        ui = %{
          "id" => ui_id,
          "type" => "reasoning",
          "turnId" => acc.turn_id,
          "summary" => ordered(summary),
          "content" => ordered(content)
        }

        # nothing for the model: a partial reasoning item cannot be replayed
        emit(acc, "item/completed", %{"item" => ui, "turnId" => acc.turn_id})
        drop_item(acc, id)
    end)
  end

  defp record_usage(state, nil, _window), do: state

  defp record_usage(%State{usage_total: total} = state, usage, window) do
    last = %{
      "inputTokens" => usage["input_tokens"] || 0,
      "cachedInputTokens" => get_in(usage, ["input_tokens_details", "cached_tokens"]) || 0,
      "outputTokens" => usage["output_tokens"] || 0,
      "reasoningOutputTokens" =>
        get_in(usage, ["output_tokens_details", "reasoning_tokens"]) || 0,
      "totalTokens" => usage["total_tokens"] || 0
    }

    total = Map.merge(total, last, fn _k, a, b -> a + b end)

    emit(state, "thread/tokenUsage/updated", %{
      "tokenUsage" => %{"modelContextWindow" => window, "last" => last, "total" => total}
    })

    %{state | usage_total: total, usage_last: last, context_window: window}
  end

  ## Tool calls

  defp dispatch(%State{model_task: nil, tools: tools} = state, calls),
    do: Enum.reduce(calls, state, &start_call(&2, &1, tools))

  defp start_call(state, %{"call_id" => call_id, "name" => name} = call, tools) do
    tool = Map.get(tools, name)
    item_id = new_id("item")
    arguments = arguments_of(call, tool)
    ui = started_ui(tool, name, item_id, arguments, state)

    emit(state, "item/started", %{"item" => ui, "turnId" => state.turn_id})
    state = append(state, :function_call, call, ui, show?: false)

    ctx = %Context{
      thread_id: state.thread_id,
      turn_id: state.turn_id,
      call_id: call_id,
      item_id: item_id,
      project_id: state.project_id,
      cwd: state.cwd,
      emit: emitter(self(), item_id),
      usage: %{last: state.usage_last, total: state.usage_total},
      context_window: state.context_window
    }

    task =
      Task.Supervisor.async_nolink(@tasks, fn -> run_tool(tool, name, arguments, ctx) end)

    timer =
      case tool do
        %Tool{timeout: ms} -> Process.send_after(self(), {:tool_timeout, task.ref}, ms)
        nil -> nil
      end

    entry = %{
      call: call,
      item_id: item_id,
      # the started item: its fields (command, changes, arguments) stay on the completed one
      ui: ui,
      tool: tool || %Tool{name: name, description: "", fun: {__MODULE__, :unknown_tool}},
      started: System.monotonic_time(:millisecond),
      output: [],
      timer: timer,
      pid: task.pid
    }

    %{state | tasks: Map.put(state.tasks, task.ref, entry)}
  end

  @doc false
  def unknown_tool(_args, _ctx), do: {:error, "unknown tool"}

  defp run_tool(nil, name, _arguments, _ctx), do: {:error, "unknown tool #{name}"}
  defp run_tool(_tool, _name, {:error, message}, _ctx), do: {:error, message}

  defp run_tool(%Tool{} = tool, _name, arguments, ctx) do
    Tool.call(tool, arguments, ctx)
  rescue
    e -> {:error, "the tool failed: " <> Exception.message(e)}
  end

  # a custom (freeform) tool call carries raw text: it becomes the one parameter
  defp arguments_of(%{"type" => "custom_tool_call", "input" => input}, %Tool{
         freeform: %{param: param}
       }),
       do: %{param => input}

  defp arguments_of(%{"type" => "custom_tool_call", "input" => input}, _tool),
    do: %{"input" => input}

  defp arguments_of(call, _tool), do: decode_arguments(call["arguments"])

  defp decode_arguments(nil), do: %{}
  defp decode_arguments(map) when is_map(map), do: map

  defp decode_arguments(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> {:error, "the arguments are not a JSON object"}
    end
  end

  defp emitter(agent, item_id),
    do: fn text -> Kernel.send(agent, {:tool_output, item_id, text}) end

  defp finish_call(%State{tasks: tasks} = state, ref, outcome) do
    {%{
       call: call,
       item_id: item_id,
       ui: started_ui,
       tool: tool,
       started: started,
       output: output,
       timer: timer
     }, tasks} = Map.pop(tasks, ref)

    if timer, do: Process.cancel_timer(timer)
    duration = System.monotonic_time(:millisecond) - started

    {text, ok?, extra} =
      case outcome do
        {:ok, text} -> {text, true, %{}}
        {:ok, text, extra} when is_map(extra) -> {text, true, extra}
        {:error, message} -> {"Error: " <> message, false, %{}}
        other -> {"Error: " <> inspect(other), false, %{}}
      end

    ui =
      Map.merge(
        started_ui,
        completed_ui(
          tool,
          item_id,
          state.turn_id,
          ok?,
          text,
          IO.iodata_to_binary(output),
          duration,
          extra
        )
      )

    input = %{"type" => output_type(call), "call_id" => call["call_id"], "output" => text}
    state = %{append(state, :function_call_output, input, ui) | tasks: tasks}
    # an image a tool attached (view_image) is queued: it goes in as a user
    # message once every call of the step has answered — a message between two
    # function outputs makes the provider refuse the request
    state =
      if is_binary(extra["image"]),
        do: %{state | pending_images: state.pending_images ++ [extra["image"]]},
        else: state

    # a tool asked for a new context window (new_context_window)
    state = if extra["compact"] == true, do: %{state | compact_requested: true}, else: state

    case {state.phase, map_size(tasks)} do
      {:dispatching, 0} -> continue_step(state)
      _ -> state
    end
  end

  defp output_type(%{"type" => "custom_tool_call"}), do: "custom_tool_call_output"
  defp output_type(_call), do: "function_call_output"

  defp attach_images(%State{pending_images: []} = state), do: state

  defp attach_images(%State{pending_images: urls} = state) do
    input = %{
      "type" => "message",
      "role" => "user",
      "content" =>
        Enum.map(urls, &%{"type" => "input_image", "image_url" => &1, "detail" => "auto"})
    }

    %{append(state, :user_message, input, nil) | pending_images: []}
  end

  # every tool answered: the images, then the next step (GenServer.call has no continue from here)
  defp continue_step(state) do
    Kernel.send(self(), :next_step)
    %{attach_images(state) | phase: :step}
  end

  ## Turn end

  defp end_turn(%State{} = state, status, error) do
    turn = %{"id" => state.turn_id, "status" => status}
    turn = if error, do: Map.put(turn, "error", %{"message" => error}), else: turn
    emit(state, "turn/completed", %{"turn" => turn})

    %State{
      state
      | phase: :idle,
        turn_id: nil,
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
            finish_call(%{acc | phase: :interrupted}, ref, {:error, @interrupted})
            | phase: acc.phase
          },
          else: %{acc | tasks: Map.delete(acc.tasks, ref)}
      end)

    if Keyword.get(opts, :close_items, true),
      do: close_open_items(state),
      else: %{state | items: %{}}
  end

  ## Transcript

  defp append_user(state, text, images) do
    ui = user_ui(new_id("item"), state.turn_id, text, images)
    emit(state, "item/started", %{"item" => ui, "turnId" => state.turn_id})
    append(state, :user_message, user_input(text, images), ui)
  end

  defp user_input(text, images) do
    content =
      [%{"type" => "input_text", "text" => text}] ++
        Enum.map(images, &%{"type" => "input_image", "image_url" => &1, "detail" => "auto"})

    %{"type" => "message", "role" => "user", "content" => content}
  end

  defp user_ui(id, turn_id, text, images) do
    content =
      [%{"type" => "text", "text" => text}] ++
        Enum.map(images, &%{"type" => "image", "url" => &1})

    %{"id" => id, "type" => "userMessage", "turnId" => turn_id, "content" => content}
  end

  # records an item (the log and the context) and shows its UI item, if any
  defp append(%State{} = state, kind, input, ui, opts \\ []) do
    seq = state.seq + 1

    Transcript.append!(%{
      thread_id: state.thread_id,
      turn_id: state.turn_id,
      seq: seq,
      kind: kind,
      input: input,
      ui: ui,
      model: if(kind in [:agent_message, :reasoning, :function_call], do: state.step_model)
    })

    if ui && Keyword.get(opts, :show?, true),
      do: emit(state, "item/completed", %{"item" => ui, "turnId" => state.turn_id})

    %{state | seq: seq, transcript: state.transcript ++ [input]}
  end

  ## UI items

  defp started_ui(%Tool{show: :command}, name, id, args, state) do
    # codex's `cmd`; a plug's own command-like tool shows its name and arguments
    command =
      case arg(args, "cmd") do
        "" -> name <> " " <> Jason.encode!(if(is_map(args), do: args, else: %{}))
        cmd -> cmd
      end

    %{
      "id" => id,
      "type" => "commandExecution",
      "turnId" => state.turn_id,
      "command" => command,
      "cwd" => state.cwd,
      "status" => "inProgress",
      "aggregatedOutput" => ""
    }
  end

  defp started_ui(%Tool{show: :file_change}, _name, id, args, state) do
    %{
      "id" => id,
      "type" => "fileChange",
      "turnId" => state.turn_id,
      "changes" => changes_from(args, state.cwd),
      "status" => "inProgress"
    }
  end

  defp started_ui(%Tool{show: :web_search}, name, id, args, state) do
    open? = name == "web_fetch" or (is_map(args) and is_binary(args["url"]))

    %{
      "id" => id,
      "type" => "webSearch",
      "turnId" => state.turn_id,
      "query" => arg(args, if(open?, do: "url", else: "query")),
      "action" =>
        if(open?,
          do: %{"type" => "openPage", "url" => arg(args, "url")},
          else: %{"type" => "search", "query" => arg(args, "query")}
        ),
      "status" => "inProgress"
    }
  end

  defp started_ui(tool, name, id, args, state) do
    %{
      "id" => id,
      "type" => "dynamicToolCall",
      "turnId" => state.turn_id,
      "namespace" => (tool && tool.namespace) || "tool",
      "tool" => name,
      "arguments" => if(is_map(args), do: args, else: %{}),
      "status" => "inProgress"
    }
  end

  defp completed_ui(%Tool{show: :command}, id, turn_id, ok?, text, streamed, duration, extra) do
    exit_code = Map.get(extra, "exitCode", if(ok?, do: 0, else: nil))
    output = if(ok?, do: streamed, else: streamed <> "\n" <> text)

    %{
      "id" => id,
      "type" => "commandExecution",
      "turnId" => turn_id,
      "status" => if(ok?, do: "completed", else: "failed"),
      "exitCode" => exit_code,
      "aggregatedOutput" => output,
      "durationMs" => Map.get(extra, "durationMs", duration)
    }
    |> Map.merge(Map.take(extra, ["command", "cwd"]))
  end

  defp completed_ui(
         %Tool{show: :file_change},
         id,
         turn_id,
         ok?,
         text,
         _streamed,
         _duration,
         extra
       ) do
    %{
      "id" => id,
      "type" => "fileChange",
      "turnId" => turn_id,
      "status" => if(ok?, do: "completed", else: "failed"),
      "output" => text
    }
    |> Map.merge(Map.take(extra, ["changes"]))
  end

  defp completed_ui(
         %Tool{show: :web_search},
         id,
         turn_id,
         ok?,
         _text,
         _streamed,
         _duration,
         extra
       ) do
    %{
      "id" => id,
      "type" => "webSearch",
      "turnId" => turn_id,
      "status" => if(ok?, do: "completed", else: "failed"),
      "results" => List.wrap(extra["results"])
    }
  end

  defp completed_ui(%Tool{} = tool, id, turn_id, ok?, text, _streamed, duration, _extra) do
    %{
      "id" => id,
      "type" => "dynamicToolCall",
      "turnId" => turn_id,
      "namespace" => tool.namespace,
      "tool" => tool.name,
      "status" => if(ok?, do: "completed", else: "failed"),
      "success" => ok?,
      "contentItems" => [%{"type" => "inputText", "text" => text}],
      "durationMs" => duration
    }
  end

  defp delta_method(:command), do: "item/commandExecution/outputDelta"
  defp delta_method(:file_change), do: "item/fileChange/outputDelta"
  defp delta_method(_), do: "item/dynamicToolCall/outputDelta"

  # what a file change will touch, known before it runs: the patch's headers
  # (apply_patch) or the one path a tool names
  defp changes_from(%{"input" => patch}, cwd) when is_binary(patch) do
    case Longx.Agent.Patch.parse(patch) do
      {:ok, hunks} ->
        Enum.map(hunks, fn
          {:add, path, _} ->
            %{"path" => Path.expand(path, cwd), "kind" => "add"}

          {:delete, path} ->
            %{"path" => Path.expand(path, cwd), "kind" => "delete"}

          {:update, path, move, _} ->
            %{"path" => Path.expand(move || path, cwd), "kind" => "update"}
        end)

      {:error, _} ->
        []
    end
  end

  defp changes_from(%{"path" => path}, cwd) when is_binary(path),
    do: [%{"path" => Path.expand(path, cwd), "kind" => "update"}]

  defp changes_from(_args, _cwd), do: []

  defp arg(args, key) when is_map(args), do: to_string(Map.get(args, key, ""))
  defp arg(_args, _key), do: ""

  ## Small helpers

  defp emit(%State{thread_id: id}, method, params),
    do: ThreadState.ingest(id, method, Map.put(params, "threadId", id))

  defp put_item(state, id, item), do: %{state | items: Map.put(state.items, id, item)}
  defp drop_item(state, id), do: %{state | items: Map.delete(state.items, id)}

  defp ui_id(%State{items: items}, id) do
    case items[id] do
      %{ui: ui_id} -> ui_id
      nil -> new_id("item")
    end
  end

  defp message_text(%{"content" => content}) when is_list(content) do
    for %{"type" => "output_text", "text" => text} <- content, into: "", do: text
  end

  defp message_text(_), do: ""

  defp texts(list) when is_list(list), do: for(%{"text" => t} <- list, do: t)
  defp texts(_), do: []

  defp ordered(map), do: map |> Enum.sort() |> Enum.map(fn {_i, t} -> t end)

  defp new_id(prefix),
    do: prefix <> "_" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)
end
