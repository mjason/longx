defmodule Longx.Agent.Config do
  @moduledoc """
  An agent *description* — data, evaluated before anything runs. Three
  layers use the same format (`priv/agent/agent.exs` shipped with Longx,
  `<data>/agent/agent.exs` for the person, `<project>/.longx/agent.exs`
  for the project) and each later layer applies to the result of the
  earlier ones (`resolve/2`):

      import Longx.Agent.Config

      agent do
        version 1
        extends :default
        model "deepseek-flash", effort: "low"
        prompt "Phoenix app; run mix test after edits."
        plug Deploy, env: "staging"           # before Request unless placed
        plug Guard, after: Environment
        options Shell, timeout_ms: 300_000
        drop Base
      end

  A description records the *difference* to the layer below — new plugs,
  options, drops, prompt text — so a release that changes the shipped
  pipeline reaches every project; an explicit `pipeline do … end` replaces
  the base wholesale and freezes it. `version` is the description format;
  an older one is flagged (`outdated?/1`) so the agent can update it.
  """

  alias Longx.Agent.Plugs.{Prompt, Request}

  @current_version 1

  @type op ::
          {:plug, module, keyword, nil | {:before | :after, module}}
          | {:options, module, keyword}
          | {:drop, module}

  @type t :: %__MODULE__{
          version: non_neg_integer,
          extends: atom | nil,
          model: String.t() | nil,
          effort: String.t() | nil,
          prompts: [String.t()],
          pipeline: [{module, keyword}] | nil,
          ops: [op]
        }

  defstruct version: @current_version,
            extends: :default,
            model: nil,
            effort: nil,
            prompts: [],
            pipeline: nil,
            ops: []

  @spec current_version() :: pos_integer
  def current_version, do: @current_version

  @spec outdated?(t) :: boolean
  def outdated?(%__MODULE__{version: v}), do: v < @current_version

  ## The DSL — entries collected in the process while the block evaluates

  @key {__MODULE__, :entries}

  defmacro agent(do: block) do
    quote do
      Longx.Agent.Config.__begin__()
      unquote(block)
      Longx.Agent.Config.__finish__()
    end
  end

  defmacro pipeline(do: block) do
    quote do
      Longx.Agent.Config.__begin_pipeline__()
      unquote(block)
      Longx.Agent.Config.__end_pipeline__()
    end
  end

  @doc false
  def __begin__, do: Process.put(@key, [])

  @doc false
  def __finish__ do
    entries = @key |> Process.delete() |> Enum.reverse()

    Enum.reduce(entries, %__MODULE__{}, fn
      {:version, v}, c -> %{c | version: v}
      {:extends, base}, c -> %{c | extends: base}
      {:model, slug, effort}, c -> %{c | model: slug, effort: effort || c.effort}
      {:prompt, text}, c -> %{c | prompts: c.prompts ++ [text]}
      {:pipeline, plugs}, c -> %{c | pipeline: plugs}
      {:op, op}, c -> %{c | ops: c.ops ++ [op]}
    end)
  end

  @doc false
  def __begin_pipeline__, do: push({:pipeline_start})

  @doc false
  def __end_pipeline__ do
    {inner, rest} = @key |> Process.get([]) |> Enum.split_while(&(&1 != {:pipeline_start}))

    plugs =
      inner |> Enum.reverse() |> Enum.map(fn {:op, {:plug, mod, opts, _}} -> {mod, opts} end)

    Process.put(@key, [{:pipeline, plugs} | tl(rest)])
  end

  defp push(entry) do
    Process.put(@key, [entry | Process.get(@key, [])])
    :ok
  end

  def version(v) when is_integer(v) and v >= 0, do: push({:version, v})
  def extends(base) when is_atom(base), do: push({:extends, base})

  def model(slug, opts \\ []) when is_binary(slug),
    do: push({:model, slug, Keyword.get(opts, :effort)})

  def prompt(text) when is_binary(text), do: push({:prompt, text})

  @doc "Mounts a plug; `before:` / `after:` place it, else it goes before `Request`."
  def plug(module, opts \\ []) when is_atom(module) and is_list(opts) do
    {position, opts} =
      case Keyword.split(opts, [:before, :after]) do
        {[before: m], rest} -> {{:before, builtin(m)}, rest}
        {[after: m], rest} -> {{:after, builtin(m)}, rest}
        {[], rest} -> {nil, rest}
      end

    push({:op, {:plug, builtin(module), opts, position}})
  end

  def options(module, opts) when is_atom(module) and is_list(opts),
    do: push({:op, {:options, builtin(module), opts}})

  def drop(module) when is_atom(module), do: push({:op, {:drop, builtin(module)}})

  # a short name (`Shell`) means the shipped plug of that name when nothing else is called so
  @doc false
  def builtin(module) do
    with false <- Code.ensure_loaded?(module),
         candidate = Module.concat(Longx.Agent.Plugs, module),
         true <- Code.ensure_loaded?(candidate) do
      candidate
    else
      _ -> module
    end
  end

  ## Resolving

  @doc "The plug list a description makes of a base list (`extends` and `ops`, or its own `pipeline`)."
  @spec resolve([{module, keyword}], t) :: [{module, keyword}]
  def resolve(_base, %__MODULE__{pipeline: plugs} = config) when is_list(plugs),
    do: plugs |> with_prompts(config)

  def resolve(base, %__MODULE__{ops: ops} = config) do
    ops
    |> Enum.reduce(base, &apply_op(&2, &1))
    |> with_prompts(config)
  end

  defp apply_op(plugs, {:plug, module, opts, position}),
    do: plugs |> Enum.reject(&match?({^module, _}, &1)) |> insert({module, opts}, position)

  defp apply_op(plugs, {:options, module, opts}) do
    Enum.map(plugs, fn
      {^module, old} -> {module, Keyword.merge(old, opts)}
      other -> other
    end)
  end

  defp apply_op(plugs, {:drop, module}), do: Enum.reject(plugs, &match?({^module, _}, &1))

  defp insert(plugs, entry, nil), do: insert(plugs, entry, {:before, Request})

  defp insert(plugs, entry, {where, anchor}) do
    case Enum.find_index(plugs, &match?({^anchor, _}, &1)) do
      nil -> plugs ++ [entry]
      i -> List.insert_at(plugs, if(where == :before, do: i, else: i + 1), entry)
    end
  end

  # the description's prompt text rides as a plug before Request
  defp with_prompts(plugs, %__MODULE__{prompts: []}), do: plugs

  defp with_prompts(plugs, %__MODULE__{prompts: prompts}) do
    Enum.reduce(prompts, plugs, &insert(&2, {Prompt, [text: &1]}, {:before, Request}))
  end
end
