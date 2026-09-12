defmodule Longx.Codex.Tool.Registry do
  @moduledoc """
  Finds every module implementing `Longx.Codex.Tool` in this application
  (plus `config :longx, Longx.Codex.Tool, extra: [...]`), minus
  `disabled: ["ns.name", ...]`, and serves lookups and codex `dynamicTools`
  specs. Built once on first use into `:persistent_term`; `reload!/0` for
  tests and hot config changes.

  Two tools with the same `{namespace, name}` are a configuration error and
  raise, never silently shadow each other.
  """

  alias Longx.Codex.Tool
  alias Longx.Codex.Tool.Context

  @key {__MODULE__, :tools}

  @type entry :: %{
          module: module,
          namespace: String.t(),
          name: String.t(),
          description: String.t(),
          input_schema: map,
          schema: ExJsonSchema.Schema.Root.t(),
          timeout: pos_integer,
          available?: (Context.t() -> boolean)
        }

  @spec all() :: [entry]
  def all do
    case :persistent_term.get(@key, nil) do
      nil -> reload!()
      tools -> tools
    end
  end

  @spec fetch(String.t(), String.t()) :: {:ok, entry} | :error
  def fetch(namespace, name) do
    case Enum.find(all(), &(&1.namespace == namespace and &1.name == name)) do
      nil -> :error
      entry -> {:ok, entry}
    end
  end

  @doc """
  The `dynamicTools` value for `thread/start`: one namespace spec per
  namespace, only tools available in `ctx`. `only: [modules]` restricts to
  those modules.
  """
  @spec specs(Context.t(), keyword) :: [map]
  def specs(%Context{} = ctx, opts \\ []) do
    all()
    |> restrict(Keyword.get(opts, :only))
    |> Enum.filter(& &1.available?.(ctx))
    |> Enum.group_by(& &1.namespace)
    |> Enum.sort_by(fn {namespace, _} -> namespace end)
    |> Enum.map(fn {namespace, tools} ->
      %{
        "type" => "namespace",
        "name" => namespace,
        "description" => "Tools provided by the #{namespace} namespace of Longx.",
        "tools" =>
          Enum.map(tools, fn tool ->
            %{
              "type" => "function",
              "name" => tool.name,
              "description" => tool.description,
              "inputSchema" => tool.input_schema
            }
          end)
      }
    end)
  end

  defp restrict(tools, nil), do: tools
  defp restrict(tools, modules), do: Enum.filter(tools, &(&1.module in modules))

  @doc "Rebuilds the registry from the application's modules and config."
  @spec reload!() :: [entry]
  def reload! do
    config = Application.get_env(:longx, Tool, [])
    disabled = config |> Keyword.get(:disabled, []) |> MapSet.new()

    tools =
      (discover() ++ Keyword.get(config, :extra, []))
      |> Enum.uniq()
      |> Enum.map(&entry/1)
      |> Enum.reject(&MapSet.member?(disabled, "#{&1.namespace}.#{&1.name}"))
      |> reject_duplicates!()

    :persistent_term.put(@key, tools)
    tools
  end

  defp discover do
    :longx
    |> Application.spec(:modules)
    |> List.wrap()
    |> Enum.filter(&implements_tool?/1)
  end

  defp implements_tool?(module) do
    Code.ensure_loaded?(module) and
      module.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()
      |> Enum.member?(Tool)
  end

  defp entry(module) do
    Code.ensure_loaded!(module)
    input_schema = module.input_schema()

    %{
      module: module,
      namespace:
        if(function_exported?(module, :namespace, 0),
          do: module.namespace(),
          else: Tool.default_namespace()
        ),
      name: module.name(),
      description: module.description(),
      input_schema: input_schema,
      schema: ExJsonSchema.Schema.resolve(input_schema),
      timeout:
        if(function_exported?(module, :timeout, 0),
          do: module.timeout(),
          else: Tool.default_timeout()
        ),
      available?:
        if(function_exported?(module, :available?, 1),
          do: &module.available?/1,
          else: fn _ -> true end
        )
    }
  end

  defp reject_duplicates!(tools) do
    tools
    |> Enum.group_by(&{&1.namespace, &1.name})
    |> Enum.each(fn
      {{ns, name}, [_, _ | _] = dups} ->
        raise ArgumentError,
              "duplicate tool #{ns}.#{name}: #{inspect(Enum.map(dups, & &1.module))}"

      _ ->
        :ok
    end)

    tools
  end
end
