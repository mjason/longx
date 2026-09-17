defmodule Longx.Agent.Step do
  @moduledoc """
  One model call in the making — the struct that flows through a
  `Longx.Agent.Pipeline`, the way a `Plug.Conn` flows through a plug
  pipeline. Plugs put three kinds of things on it: *instructions* (text for
  the prompt, in order), *skills* (a name and a line for the prompt's list,
  the body read on demand) and *tools* (what the model may call; a
  `Longx.Agent.Tool`). A plug may also `halt/2` — the model is not called
  and the turn ends with the reason.

  `transcript` is the conversation so far as Responses API input items;
  `model` / `effort` are what this step calls (the person's choice unless a
  plug or a tool changed them); `request` is what the last plug built.

  The same pipeline runs at three **phases** of the loop, `phase` says
  which: `:request` (before the model — prompt, tools, the request),
  `:response` (the model answered; `calls` are the tool calls it made,
  none yet run) and `:turn_end` (nothing left to do; the turn is about to
  end). What a plug wants the kernel to do is an **effect** on the step,
  data the kernel interprets: `enqueue_call/3` (run a tool call of the
  plug's own, at `:response`), `continue/2` (another step with this text
  instead of ending, at `:turn_end`), `compact/2` (fold the context, at
  `:request`), and `halt/2` (end the turn). `usage` (`last` / `total`
  token counts so far) and `context_window` let a plug judge the context.
  """

  alias Longx.Agent.Tool

  @type skill :: %{name: String.t(), description: String.t(), body: String.t() | nil}
  @type phase :: :request | :response | :turn_end
  @type call :: %{id: String.t() | nil, call_id: String.t(), name: String.t(), arguments: map}
  @type effect ::
          {:call, String.t(), map} | {:continue, String.t()} | {:compact, keyword}

  @type t :: %__MODULE__{
          thread_id: String.t() | nil,
          turn_id: String.t() | nil,
          project_id: String.t() | nil,
          cwd: String.t() | nil,
          model: String.t() | nil,
          effort: String.t() | nil,
          transcript: [map],
          instructions: [String.t()],
          skills: %{String.t() => skill},
          tools: %{String.t() => Tool.t()},
          raw_tools: [map],
          request: map | nil,
          phase: phase,
          calls: [call],
          effects: [effect],
          usage: %{last: map | nil, total: map},
          context_window: pos_integer | nil,
          halted: boolean,
          reason: term,
          assigns: map,
          state: map
        }

  defstruct thread_id: nil,
            turn_id: nil,
            project_id: nil,
            cwd: nil,
            model: nil,
            effort: nil,
            transcript: [],
            instructions: [],
            skills: %{},
            tools: %{},
            raw_tools: [],
            request: nil,
            phase: :request,
            calls: [],
            effects: [],
            usage: %{last: nil, total: %{}},
            context_window: nil,
            halted: false,
            reason: nil,
            assigns: %{},
            # kept by the kernel across the phases and steps of a turn (a
            # strategy counts its rounds here); fresh at every turn
            state: %{}

  @spec new(keyword) :: t
  def new(fields \\ []), do: struct!(__MODULE__, fields)

  @doc "Appends a piece of prompt text (nil and blank are ignored)."
  @spec instructions(t, String.t() | nil | [String.t() | nil]) :: t
  def instructions(%__MODULE__{} = step, texts) when is_list(texts),
    do: Enum.reduce(texts, step, &instructions(&2, &1))

  def instructions(%__MODULE__{} = step, nil), do: step

  def instructions(%__MODULE__{instructions: acc} = step, text) when is_binary(text) do
    case String.trim(text) do
      "" -> step
      _ -> %{step | instructions: acc ++ [text]}
    end
  end

  @doc "Declares a skill: a line in the prompt's list; `body:` is what the model reads on demand."
  @spec skill(t, String.t(), String.t(), keyword) :: t
  def skill(%__MODULE__{skills: skills} = step, name, description, opts \\ [])
      when is_binary(name) and is_binary(description) do
    %{
      step
      | skills:
          Map.put(skills, name, %{
            name: name,
            description: description,
            body: Keyword.get(opts, :body)
          })
    }
  end

  @doc "Mounts a tool (a later declaration of the same name replaces an earlier one)."
  @spec tool(t, Tool.t()) :: t
  def tool(%__MODULE__{tools: tools} = step, %Tool{name: name} = tool),
    do: %{step | tools: Map.put(tools, name, tool)}

  @spec tools(t, [Tool.t()]) :: t
  def tools(%__MODULE__{} = step, list) when is_list(list),
    do: Enum.reduce(list, step, &tool(&2, &1))

  @doc "Adds a tool the provider itself runs (`%{\"type\" => \"web_search\"}`), passed to the request as is."
  @spec raw_tool(t, map) :: t
  def raw_tool(%__MODULE__{raw_tools: raw} = step, %{"type" => _} = tool),
    do: %{step | raw_tools: Enum.reject(raw, &(&1["type"] == tool["type"])) ++ [tool]}

  @doc "Stops the pipeline: the model is not called and the turn ends with `reason`."
  @spec halt(t, term) :: t
  def halt(%__MODULE__{} = step, reason), do: %{step | halted: true, reason: reason}

  @spec assign(t, atom, term) :: t
  def assign(%__MODULE__{assigns: assigns} = step, key, value) when is_atom(key),
    do: %{step | assigns: Map.put(assigns, key, value)}

  @doc "Remembers something for the rest of the turn (`step.state`)."
  @spec put_state(t, atom, term) :: t
  def put_state(%__MODULE__{state: st} = step, key, value) when is_atom(key),
    do: %{step | state: Map.put(st, key, value)}

  ## Effects

  @doc "Asks the kernel to run a tool call of the plug's own (with the model's, at `:response`)."
  @spec enqueue_call(t, String.t(), map) :: t
  def enqueue_call(%__MODULE__{} = step, name, arguments)
      when is_binary(name) and is_map(arguments),
      do: effect(step, {:call, name, arguments})

  @doc "Asks the kernel for another step with this text instead of ending the turn (at `:turn_end`)."
  @spec continue(t, String.t()) :: t
  def continue(%__MODULE__{} = step, text) when is_binary(text),
    do: effect(step, {:continue, text})

  @doc "Asks the kernel to fold the context before the model is called (at `:request`)."
  @spec compact(t, keyword) :: t
  def compact(%__MODULE__{} = step, opts \\ []) when is_list(opts),
    do: effect(step, {:compact, opts})

  @doc """
  Asks the kernel to start a child agent `name` on `task` (any phase). Its
  report comes back as a message from `name`. Options as `Longx.Agent.spawn/4`.
  """
  @spec spawn(t, String.t(), String.t(), keyword) :: t
  def spawn(%__MODULE__{} = step, name, task, opts \\ [])
      when is_binary(name) and is_binary(task) and is_list(opts),
      do: effect(step, {:spawn, name, task, opts})

  @doc "Asks the kernel to change the thread's goal (status, objective, budget) — any phase."
  @spec goal(t, map) :: t
  def goal(%__MODULE__{} = step, attrs) when is_map(attrs), do: effect(step, {:goal, attrs})

  defp effect(%__MODULE__{effects: effects} = step, effect),
    do: %{step | effects: effects ++ [effect]}
end
