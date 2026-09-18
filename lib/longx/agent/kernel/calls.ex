defmodule Longx.Agent.Kernel.Calls do
  @moduledoc false
  # Tool calls: one task per call, its output streamed to the view, its result into the transcript, the next step once every call of the step answered.

  alias Longx.Agent.{Context, Tool}
  alias Longx.Agent.Kernel.{State, UI}
  import Longx.Agent.Kernel.State
  @tasks Longx.Agent.TaskSupervisor

  ## Tool calls

  def dispatch(%State{model_task: nil, tools: tools} = state, calls),
    do: Enum.reduce(calls, state, &start_call(&2, &1, tools))

  def start_call(state, %{"call_id" => call_id, "name" => name} = call, tools) do
    tool = Map.get(tools, name)
    item_id = new_id("item")
    arguments = arguments_of(call, tool)
    ui = UI.started_ui(tool, name, item_id, arguments, state)

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

  def run_tool(nil, name, _arguments, _ctx), do: {:error, "unknown tool #{name}"}
  def run_tool(_tool, _name, {:error, message}, _ctx), do: {:error, message}

  def run_tool(%Tool{} = tool, _name, arguments, ctx) do
    Tool.call(tool, arguments, ctx)
  rescue
    e -> {:error, "the tool failed: " <> Exception.message(e)}
  end

  # a custom (freeform) tool call carries raw text: it becomes the one parameter
  def arguments_of(%{"type" => "custom_tool_call", "input" => input}, %Tool{
        freeform: %{param: param}
      }),
      do: %{param => input}

  def arguments_of(%{"type" => "custom_tool_call", "input" => input}, _tool),
    do: %{"input" => input}

  def arguments_of(call, tool) do
    case decode_arguments(call["arguments"]) do
      {:error, _} = error -> error
      arguments -> Tool.prepare(tool, arguments)
    end
  end

  def decode_arguments(nil), do: %{}
  def decode_arguments(map) when is_map(map), do: map

  def decode_arguments(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> {:error, "the arguments are not a JSON object"}
    end
  end

  def emitter(agent, item_id),
    do: fn text -> Kernel.send(agent, {:tool_output, item_id, text}) end

  def finish_call(%State{tasks: tasks} = state, ref, outcome) do
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
        UI.completed_ui(
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
    # a card the tool made for the person (Context.present after the fact)
    state = if is_map(extra["present"]), do: present(state, extra["present"]), else: state

    case {state.phase, map_size(tasks)} do
      {:dispatching, 0} -> continue_step(state)
      _ -> state
    end
  end

  @doc """
  A card from a tool (`Context.present/2`): a completed `longx.present`
  item on the thread — the same shape as the model's own `present` call,
  so the client draws both alike — logged as a UI-only transcript row that
  is never model input.
  """
  def present(%State{} = state, tree) do
    ui = UI.present_ui(new_id("item"), state.turn_id, tree)
    append(state, :activity, %{"type" => "longx_present"}, ui, context?: false)
  end

  def output_type(%{"type" => "custom_tool_call"}), do: "custom_tool_call_output"
  def output_type(_call), do: "function_call_output"

  def attach_images(%State{pending_images: []} = state), do: state

  def attach_images(%State{pending_images: urls} = state) do
    input = %{
      "type" => "message",
      "role" => "user",
      "content" =>
        Enum.map(urls, &%{"type" => "input_image", "image_url" => &1, "detail" => "auto"})
    }

    %{append(state, :user_message, input, nil) | pending_images: []}
  end

  # every tool answered: the images, then the next step (GenServer.call has no continue from here)
  def continue_step(state) do
    Kernel.send(self(), :next_step)
    %{attach_images(state) | phase: :step}
  end
end
