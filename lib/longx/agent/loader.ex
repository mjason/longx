defmodule Longx.Agent.Loader do
  @moduledoc """
  Loads the layered agent description for a working directory:

  1. the shipped default — `Longx.Agent.Pipelines.Default.config/0`;
  2. the person's — `<data>/agent/` (`config :longx, Longx.Agent.Loader,
     global_dir:`), every project;
  3. the project's — `<root>/.longx/`, only when the project is trusted.

  A layer is `agent.exs` (evaluated; must return a `Longx.Agent.Config`)
  plus `plugs/**/*.exs` (modules using `Longx.Agent.Plug`). The `.exs`
  code is data first: every `defmodule` in a layer, and every reference
  to it, is renamed under `Longx.Agent.Local.<tag>` before it is compiled
  — two projects may both define `Deploy`. Each layer is cached by the
  mtimes of its files and recompiled when one changes (old modules are
  purged when no longer defined); a file that fails to load leaves the
  layer below in force and becomes a *notice* the kernel puts in front of
  the model, so an agent that broke its own definition can fix it. An
  outdated `version` is a notice too. `load/2` answers the plugs, the
  description's model / effort, the errors, the notices and whether the
  project has a `.longx/` at all (`present?`) — what the kernel and the
  settings page want.
  """

  alias Longx.Agent.Config
  alias Longx.Agent.Plugs.{Local, Request}

  @namespace [:Longx, :Agent, :Local]

  @type loaded :: %{
          plugs: [{module, keyword}],
          model: String.t() | nil,
          effort: String.t() | nil,
          errors: [%{layer: atom, file: String.t(), message: String.t()}],
          notices: [String.t()],
          present?: boolean,
          layers: [map]
        }

  @doc "The person's global layer directory."
  @spec global_dir() :: Path.t()
  def global_dir do
    :longx
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get_lazy(:global_dir, fn ->
      Path.join(Path.dirname(Longx.Codex.Home.default_dir()), "agent")
    end)
  end

  @doc """
  The resolved description for `root`. Options: `tag:` (the project's
  namespace segment — its id; defaults to a hash of the root), `trusted:`
  (whether the project's own `.longx/` may be loaded).
  """
  @spec load(Path.t(), keyword) :: loaded
  def load(root, opts \\ []) do
    tag = Keyword.get(opts, :tag) || tag_for(root)
    trusted? = Keyword.get(opts, :trusted, false)
    project_dir = Path.join(root, ".longx")

    global = layer(:global, global_dir(), "Global")

    project =
      cond do
        not File.dir?(project_dir) ->
          nil

        not trusted? ->
          # listed for the settings page, loaded for nobody
          %{
            name: :project,
            dir: project_dir,
            skipped: :untrusted,
            errors: [],
            config: nil,
            files: files(project_dir)
          }

        true ->
          layer(:project, project_dir, tag)
      end

    layers = Enum.reject([global, project], &is_nil/1)
    configs = for %{config: %Config{} = c} <- layers, do: c

    {plugs, missing} =
      configs
      |> Enum.reduce(Longx.Agent.Pipelines.Default.plugs(), &Config.resolve(&2, &1))
      |> with_local(project, root)
      |> Enum.split_with(fn {module, _} -> plug?(module) end)

    errors =
      Enum.flat_map(layers, & &1.errors) ++
        Enum.map(missing, fn {module, _} ->
          %{
            layer: :project,
            file: "agent.exs",
            message:
              "plug #{inspect(module)} is not available (its file failed to load, or the name is wrong); skipped"
          }
        end)

    %{
      plugs: plugs,
      model: last(configs, & &1.model),
      effort: last(configs, & &1.effort),
      errors: errors,
      notices: notices(errors, configs),
      present?: File.dir?(project_dir),
      layers: layers
    }
  end

  defp plug?(module), do: Code.ensure_loaded?(module) and function_exported?(module, :call, 2)

  defp last(configs, fun), do: configs |> Enum.map(fun) |> Enum.reject(&is_nil/1) |> List.last()

  # the growth plug: only a trusted project that has a .longx (or wants one)
  defp with_local(plugs, %{skipped: :untrusted}, _root), do: plugs
  defp with_local(plugs, nil, _root), do: plugs

  defp with_local(plugs, _layer, root) do
    entry = {Local, [root: root]}

    case Enum.find_index(plugs, &match?({Request, _}, &1)) do
      nil -> plugs ++ [entry]
      i -> List.insert_at(plugs, i, entry)
    end
  end

  defp notices(errors, configs) do
    Enum.map(errors, fn %{file: file, message: message} ->
      "⚠ The agent definition file #{file} failed to load and was skipped: #{message}"
    end) ++
      for %Config{version: v} = c <- configs, Config.outdated?(c) do
        "⚠ An agent description declares version #{v}; the current format is version #{Config.current_version()}. Update it when convenient (see the Longx knowledge on agent descriptions)."
      end
  end

  defp tag_for(root), do: "R" <> (root |> :erlang.phash2() |> Integer.to_string(36))

  ## One layer, cached by the mtimes of its files

  defp layer(name, dir, tag) do
    files = files(dir)
    key = {name, dir}

    case __MODULE__.Cache.get(key) do
      %{files: ^files} = cached ->
        cached

      previous ->
        loaded = build(name, dir, tag, files, previous)
        __MODULE__.Cache.put(key, loaded)
        loaded
    end
  end

  # every file of the layer with its mtime (the cache key)
  defp files(dir) do
    if File.dir?(dir) do
      [Path.join(dir, "agent.exs") | Path.wildcard(Path.join(dir, "plugs/**/*.exs"))]
      |> Enum.filter(&File.regular?/1)
      |> Enum.sort()
      # mtime and size: a rewrite within the same second still counts when the size moved
      |> Enum.map(fn path ->
        %{mtime: mtime, size: size} = File.stat!(path, time: :posix)
        {path, {mtime, size}}
      end)
    else
      []
    end
  end

  defp build(name, dir, tag, files, previous) do
    prefix = @namespace ++ [String.to_atom(tag)]
    plug_files = for {path, _} <- files, Path.basename(path) != "agent.exs", do: path

    {sources, errors} =
      Enum.reduce(plug_files, {[], []}, fn path, {ok, errs} ->
        case parse(path) do
          {:ok, ast} -> {[{path, ast} | ok], errs}
          {:error, message} -> {ok, [%{layer: name, file: path, message: message} | errs]}
        end
      end)

    sources = Enum.reverse(sources)

    # names of the modules this layer defines — the ones from files that fail
    # to parse today keep their mapping from the last good build, so the
    # description's references stay stable (the plug is then reported missing)
    defined =
      Enum.uniq(
        Enum.flat_map(sources, fn {_path, ast} -> defined_modules(ast) end) ++
          ((is_map(previous) && previous[:defined]) || [])
      )

    {modules, errors} =
      Enum.reduce(sources, {[], errors}, fn {path, ast}, {mods, errs} ->
        case compile(path, rename(ast, defined, prefix)) do
          {:ok, new} -> {mods ++ new, errs}
          {:error, message} -> {mods, [%{layer: name, file: path, message: message} | errs]}
        end
      end)

    purge(previous, modules)

    {config, errors} =
      case Enum.find(files, fn {path, _} -> Path.basename(path) == "agent.exs" end) do
        nil -> {nil, errors}
        {path, _} -> evaluate(path, defined, prefix, name, errors)
      end

    %{
      name: name,
      dir: dir,
      files: files,
      modules: modules,
      defined: defined,
      config: config,
      errors: Enum.reverse(errors)
    }
  end

  defp parse(path) do
    case Code.string_to_quoted(File.read!(path), file: path, columns: true) do
      {:ok, ast} -> {:ok, ast}
      {:error, {meta, message, token}} -> {:error, "#{path}:#{line(meta)}: #{message}#{token}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp line(meta), do: Keyword.get(meta, :line, "?")

  # the modules a file defines at its top level (or inside a block), as alias parts
  defp defined_modules(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _, [{:__aliases__, _, parts} | _]} = node, acc -> {node, [parts | acc]}
        node, acc -> {node, acc}
      end)

    Enum.reverse(acc)
  end

  # every alias that names a module of this layer (or a submodule of one) gets the layer's prefix
  defp rename(ast, [], _prefix), do: ast

  defp rename(ast, defined, prefix) do
    Macro.prewalk(ast, fn
      {:__aliases__, meta, parts} = node ->
        if Enum.any?(defined, &List.starts_with?(parts, &1)) and
             not List.starts_with?(parts, prefix),
           do: {:__aliases__, meta, prefix ++ parts},
           else: node

      node ->
        node
    end)
  end

  defp compile(path, ast) do
    {:ok, ast |> Code.compile_quoted(path) |> Enum.map(&elem(&1, 0))}
  rescue
    e -> {:error, "#{path}: " <> Exception.message(e)}
  end

  # modules of the previous build that this one no longer defines go away
  defp purge(%{modules: old}, new) when is_list(old) do
    for module <- old -- new do
      :code.soft_purge(module)
      :code.delete(module)
    end

    :ok
  end

  defp purge(_previous, _new), do: :ok

  defp evaluate(path, defined, prefix, name, errors) do
    with {:ok, ast} <- parse(path),
         {%Config{} = config, _} <- Code.eval_quoted(rename(ast, defined, prefix), [], file: path) do
      {config, errors}
    else
      {:error, message} ->
        {nil, [%{layer: name, file: path, message: message} | errors]}

      {_other, _binding} ->
        {nil,
         [
           %{
             layer: name,
             file: path,
             message:
               "#{path} must return an agent description (import Longx.Agent.Config; agent do … end)"
           }
           | errors
         ]}
    end
  rescue
    e ->
      {nil, [%{layer: name, file: path, message: "#{path}: " <> Exception.message(e)} | errors]}
  end

  defmodule Cache do
    @moduledoc false
    use GenServer

    @table :longx_agent_layers

    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    def get(key) do
      case :ets.lookup(@table, key) do
        [{^key, value}] -> value
        [] -> nil
      end
    end

    def put(key, value), do: GenServer.call(__MODULE__, {:put, key, value})

    @impl true
    def init(_opts) do
      :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
      {:ok, %{}}
    end

    @impl true
    def handle_call({:put, key, value}, _from, state) do
      :ets.insert(@table, {key, value})
      {:reply, :ok, state}
    end
  end
end
