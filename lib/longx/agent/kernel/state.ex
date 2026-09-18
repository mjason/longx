defmodule Longx.Agent.Kernel.State do
  @moduledoc false
  # The kernel's state and the primitives every part of it uses: emitting an
  # event to the thread's view, appending an item to the transcript, ids.

  alias __MODULE__, as: State
  alias Longx.Agent.{ThreadState, Transcript}

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
            # when the turn began (epoch ms) — the turn's stamps for the UI's badge
            turn_started_at: nil,
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
            pending_images: [],
            # this agent's place in a team: who spawned it, what it is called,
            # who it spawned (child thread id → %{name, pid, ref, status, role, task, n};
            # a child stays a member after its turn — done, idle, failed — until closed)
            parent: nil,
            # who the answer of the running turn goes to (the parent by default): a
            # teammate that asked gets it in its own mailbox
            reply_to: nil,
            name: nil,
            # the declared role this agent runs as (its description on top of the project's)
            role: nil,
            # how many parents above (the Agents plug's depth limit)
            depth: 0,
            # codex's agent path ("/root", "/root/researcher"): the UI's name for the agent
            path: "/root",
            children: %{},
            # `step.state`: kept across the phases and steps of one turn
            turn_state: %{},
            # how this agent's children are made (Longx.Projects gives them rows)
            spawner: nil,
            # the settings page's layer, read per turn (Longx.Agent.Definition.Settings map or nil)
            settings: nil,
            # the models the agent may name (Longx.AI.model_choices/0), read per step; nil = unknown
            models: nil,
            # the asks tools have open (Context.ask): id → %{from, timer, callback?}
            asks: %{},
            # the thread's goal (codex's shape: objective, status, tokenBudget,
            # tokensUsed, timeUsedSeconds), kept in the view across restarts
            goal: nil,
            # leaves after this long idle (nil never); comes back on demand
            idle_ms: nil,
            last_active: nil

  def touch(state), do: %{state | last_active: System.monotonic_time(:millisecond)}

  ## Transcript

  def append_user(state, text, images, from \\ nil) do
    ui = user_ui(new_id("item"), state.turn_id, text, images, from)
    emit(state, "item/started", %{"item" => ui, "turnId" => state.turn_id})
    append(state, :user_message, user_input(text, images), ui)
  end

  def user_input(text, images) do
    content =
      [%{"type" => "input_text", "text" => text}] ++
        Enum.map(images, &%{"type" => "input_image", "image_url" => &1, "detail" => "auto"})

    %{"type" => "message", "role" => "user", "content" => content}
  end

  def user_ui(id, turn_id, text, images, from) do
    content =
      [%{"type" => "text", "text" => text}] ++
        Enum.map(images, &%{"type" => "image", "url" => &1})

    ui = %{"id" => id, "type" => "userMessage", "turnId" => turn_id, "content" => content}
    if from, do: Map.put(ui, "from", from), else: ui
  end

  # records an item (the log and the context) and shows its UI item, if any
  def append(%State{} = state, kind, input, ui, opts \\ []) do
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

    # a UI-only item (a sub-agent's activity) is logged but never model input
    if Keyword.get(opts, :context?, true),
      do: %{state | seq: seq, transcript: state.transcript ++ [input]},
      else: %{state | seq: seq}
  end

  ## Small helpers

  def emit(%State{thread_id: id}, method, params),
    do: ThreadState.ingest(id, method, Map.put(params, "threadId", id))

  def put_item(state, id, item), do: %{state | items: Map.put(state.items, id, item)}
  def drop_item(state, id), do: %{state | items: Map.delete(state.items, id)}

  def ui_id(%State{items: items}, id) do
    case items[id] do
      %{ui: ui_id} -> ui_id
      nil -> new_id("item")
    end
  end

  def message_text(%{"content" => content}) when is_list(content) do
    for %{"type" => "output_text", "text" => text} <- content, into: "", do: text
  end

  def message_text(_), do: ""

  def texts(list) when is_list(list), do: for(%{"text" => t} <- list, do: t)
  def texts(_), do: []

  def ordered(map), do: map |> Enum.sort() |> Enum.map(fn {_i, t} -> t end)

  def new_id(prefix),
    do: prefix <> "_" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

  def describe(reason) when is_binary(reason), do: reason
  def describe(reason), do: inspect(reason)
end
