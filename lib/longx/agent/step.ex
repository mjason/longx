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
  """

  alias Longx.Agent.Tool

  @type skill :: %{name: String.t(), description: String.t(), body: String.t() | nil}

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
          request: map | nil,
          halted: boolean,
          reason: term,
          assigns: map
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
            request: nil,
            halted: false,
            reason: nil,
            assigns: %{}

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

  @doc "Stops the pipeline: the model is not called and the turn ends with `reason`."
  @spec halt(t, term) :: t
  def halt(%__MODULE__{} = step, reason), do: %{step | halted: true, reason: reason}

  @spec assign(t, atom, term) :: t
  def assign(%__MODULE__{assigns: assigns} = step, key, value) when is_atom(key),
    do: %{step | assigns: Map.put(assigns, key, value)}
end
