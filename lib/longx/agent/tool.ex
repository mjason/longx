defmodule Longx.Agent.Tool do
  @moduledoc """
  A function the model may call, as a plug declares it (`tool` in
  `Longx.Agent.Plug`): the name and description the model sees, a JSON
  schema for the arguments, the function that runs it (`{module, fun}`,
  called with the decoded arguments and a `Longx.Agent.Context`), how the
  UI shows a call (`show`: `:command` as a command row, `:file_change` as
  a file change, `:web_search` as a search / page row, `:tool` as a
  generic tool row) and a timeout.

  `call/3` validates the arguments against the schema first — the model
  gets the schema's complaint back and can fix the call.
  """

  alias Longx.Agent.Context

  @type show :: :command | :file_change | :tool | :web_search
  @type outcome :: {:ok, String.t()} | {:ok, String.t(), map} | {:error, String.t()}

  @type t :: %__MODULE__{
          name: String.t(),
          namespace: String.t(),
          description: String.t(),
          schema: map,
          fun: {module, atom} | (map, Context.t() -> outcome),
          show: show,
          timeout: pos_integer,
          freeform: %{syntax: String.t(), definition: String.t(), param: String.t()} | nil,
          prepare: (map -> map) | nil
        }

  @enforce_keys [:name, :description, :fun]
  defstruct name: nil,
            namespace: "tool",
            description: "",
            schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
            fun: nil,
            show: :tool,
            timeout: 60_000,
            # a grammar-constrained *custom* tool for providers that run them
            # (OpenAI): the model sends raw text, which lands in `param`
            freeform: nil,
            # the arguments straightened before validation and before the UI
            # item is made (a nested array a model sent as a JSON string)
            prepare: nil

  @type param :: {atom, param_type, String.t() | nil, keyword}
  @type param_type ::
          :string
          | :integer
          | :number
          | :boolean
          | :map
          | {:enum, [String.t()]}
          | {:array, param_type}

  @doc """
  Builds a tool from a `tool` declaration: the params become the JSON
  schema — or `schema:` is one already (a vocabulary generated elsewhere,
  like `present`'s).
  """
  @spec declare(module, atom, String.t(), [param], keyword) :: t
  def declare(module, name, description, params, opts) do
    %__MODULE__{
      name: Atom.to_string(name),
      namespace: Keyword.get(opts, :namespace, namespace_of(module)),
      description: description,
      schema: Keyword.get(opts, :schema) || schema(params),
      fun: {module, name},
      show: Keyword.get(opts, :show, :tool),
      timeout: Keyword.get(opts, :timeout, 60_000),
      freeform: Keyword.get(opts, :freeform),
      prepare: Keyword.get(opts, :prepare)
    }
  end

  @doc "The arguments as the tool wants them: `prepare:` applied when the tool has one."
  @spec prepare(t | nil, map) :: map
  def prepare(%__MODULE__{prepare: fun}, arguments)
      when is_function(fun, 1) and is_map(arguments),
      do: fun.(arguments)

  def prepare(_tool, arguments), do: arguments

  @doc "The plug module's last segment, lower-cased: `Plugs.Shell` → `\"shell\"`."
  @spec namespace_of(module) :: String.t()
  def namespace_of(module),
    do: module |> Module.split() |> List.last() |> Macro.underscore()

  @spec schema([param]) :: map
  def schema(params) do
    properties =
      Map.new(params, fn {name, type, doc, _opts} ->
        {Atom.to_string(name), type_schema(type) |> put_doc(doc)}
      end)

    required =
      for {name, _type, _doc, opts} <- params,
          Keyword.get(opts, :required, false),
          do: Atom.to_string(name)

    %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => false
    }
  end

  defp type_schema(:string), do: %{"type" => "string"}
  defp type_schema(:integer), do: %{"type" => "integer"}
  defp type_schema(:number), do: %{"type" => "number"}
  defp type_schema(:boolean), do: %{"type" => "boolean"}

  defp type_schema(:map),
    do: %{"type" => "object", "additionalProperties" => %{"type" => "string"}}

  defp type_schema({:enum, values}), do: %{"type" => "string", "enum" => values}
  defp type_schema({:array, type}), do: %{"type" => "array", "items" => type_schema(type)}

  defp put_doc(schema, nil), do: schema
  defp put_doc(schema, doc), do: Map.put(schema, "description", doc)

  @doc """
  Runs the tool: the arguments are checked against the schema (the
  complaint is the error the model reads), then the function is applied.
  A raise inside the function is an error with its message.
  """
  @spec call(t, map, Context.t() | map) :: outcome
  def call(%__MODULE__{} = tool, arguments, context) when is_map(arguments) do
    arguments = prepare(tool, arguments)

    case validate(tool.schema, arguments) do
      :ok -> apply_fun(tool.fun, arguments, context)
      {:error, message} -> {:error, message}
    end
  end

  defp apply_fun({module, fun}, arguments, context), do: apply(module, fun, [arguments, context])
  defp apply_fun(fun, arguments, context) when is_function(fun, 2), do: fun.(arguments, context)

  @spec validate(map, map) :: :ok | {:error, String.t()}
  def validate(schema, arguments) do
    case ExJsonSchema.Validator.validate(ExJsonSchema.Schema.resolve(schema), arguments) do
      :ok ->
        :ok

      {:error, errors} ->
        {:error,
         "invalid arguments: " <>
           Enum.map_join(errors, "; ", fn {message, path} -> "#{path}: #{message}" end)}
    end
  end

  @doc """
  The tool as a Responses API tool: a `function` (every provider), or —
  for a provider that runs grammar-constrained custom tools and a tool that
  declares a `freeform` grammar — a `custom` tool (`to_custom/1`).
  """
  @spec to_responses(t) :: map
  def to_responses(%__MODULE__{} = tool) do
    %{
      "type" => "function",
      "name" => tool.name,
      "description" => tool.description,
      "parameters" => tool.schema,
      "strict" => false
    }
  end

  @spec to_custom(t) :: map | nil
  def to_custom(%__MODULE__{freeform: nil}), do: nil

  def to_custom(%__MODULE__{freeform: %{syntax: syntax, definition: definition}} = tool) do
    %{
      "type" => "custom",
      "name" => tool.name,
      "description" => tool.description,
      "format" => %{"type" => "grammar", "syntax" => syntax, "definition" => definition}
    }
  end
end
