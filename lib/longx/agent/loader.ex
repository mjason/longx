defmodule Longx.Agent.Loader do
  @moduledoc """
  Loads the layered agent description for a working directory:

  1. the shipped default — `Longx.Agent.Pipelines.Default.config/0`;
  2. the person's — `<data>/agent/` (`config :longx, Longx.Agent.Loader,
     global_dir:`), every project;
  3. the project's **shared** tree — `<root>/.longx/` (`agent.exs`,
     `shared/plugs/`, `shared/agents/`; the flat `plugs/` and `agents/`
     of before count as shared) — in git, reviewed;
  4. the project's **local** tree — `<root>/.longx/local/` (its own
     `agent.exs`, `plugs/`, `agents/`) — gitignored, this machine's and
     the agent's drafts.

  The shared tree loads only when the project is trusted (its code came
  with the clone); the local tree always does — it is this machine's, what
  the agent itself wrote, and it never came from anywhere. A layer is a
  description (`agent.exs`; must return a `Longx.Agent.Config`), its plugs
  (`plugs/**/*.exs`, modules using `Longx.Agent.Plug`) and its **roles**:
  `agents/<name>/agent.exs`, each a description of its own with a
  `prompt.md` (`prompt_file`) and, optionally, its own `plugs/` and
  `knowledge/`. Longx ships no roles: a project grows its own — the agent
  declares one in `local/` when a kind of task keeps being delegated, the
  person promotes it to `shared/`. `load(root, agent: name)` gives the role's pipeline — the
  main stack with the role's descriptions (every layer's, in order) on top
  — and `agents` lists every declared role with its summary, `allowed`
  the names the loaded agent may spawn (`agents [...]`; nil = all).

  The `.exs` code is data first: every `defmodule` in a layer, and every
  reference to it, is renamed under `Longx.Agent.Local.<tag>` before it
  is compiled — two projects may both define `Deploy`. Each layer is
  cached by the mtimes of its files and recompiled when one changes (old
  modules are purged when no longer defined); a file that fails to load
  leaves the layer below in force and becomes a *notice* the kernel puts
  in front of the model, so an agent that broke its own definition can
  fix it. An outdated `version` is a notice too.
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
          layers: [map],
          trusted?: boolean,
          agents: [%{name: String.t(), summary: String.t(), layer: atom}],
          allowed: [String.t()] | nil,
          agent: String.t() | nil
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
  (whether the project's own `.longx/` may be loaded), `agent:` (a role
  name: that agent's description on top of the project's), `settings:`
  (a `Longx.Agent.Settings` map — the settings page's layer, applied last:
  the Agents plug's limits, the default child model, the reviewer model),
  `overrides:` (a `Longx.Agent.Config` applied after everything).
  """
  @spec load(Path.t(), keyword) :: loaded
  def load(root, opts \\ []) do
    tag = Keyword.get(opts, :tag) || tag_for(root)
    trusted? = Keyword.get(opts, :trusted, false)
    role = Keyword.get(opts, :agent)
    project_dir = Path.join(root, ".longx")
    local_dir = Path.join(project_dir, "local")

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
            roles: %{},
            defined: [],
            files: files(:project, project_dir)
          }

        true ->
          layer(:project, project_dir, tag)
      end

    # the local tree shares the project's namespace: its description may name
    # the shared plugs, and a module of the same name overrides
    local =
      if File.dir?(local_dir),
        do: layer(:local, local_dir, tag, extra_defined: (project && project.defined) || []),
        else: nil

    layers = Enum.reject([global, project, local], &is_nil/1)
    {roles, role_file_errors} = roles(layers)

    # the main stack: every layer's description; then the role's, layer by layer
    main = for %{dir: dir, config: %Config{} = c} <- layers, do: {c, dir}

    {role_configs, role_errors} =
      case {role, Map.get(roles, role)} do
        {nil, _} ->
          {[], []}

        {name, nil} ->
          {[],
           [
             %{
               layer: :project,
               file: "agents/#{name}/agent.exs",
               message:
                 "no agent named #{inspect(name)} is declared (shared/agents/#{name}/agent.exs or local/agents/#{name}/agent.exs in .longx, or the global directory)"
             }
           ]}

        {_name, %{config: config, dir: dir}} ->
          {[{config, dir}], []}
      end

    {configs, prompt_errors} = with_prompt_files(main ++ role_configs)

    configs =
      configs ++
        settings_layer(Keyword.get(opts, :settings), role, last(configs, & &1.model)) ++
        List.wrap(Keyword.get(opts, :overrides))

    {plugs, missing} =
      configs
      |> Enum.reduce(Longx.Agent.Pipelines.Default.plugs(), &Config.resolve(&2, &1))
      |> with_local(project_dir, root, trusted?)
      |> Enum.split_with(fn {module, _} -> plug?(module) end)

    errors =
      Enum.flat_map(layers, & &1.errors) ++
        role_file_errors ++
        role_errors ++
        prompt_errors ++
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
      trusted?: trusted?,
      layers: layers,
      agents: roles |> Map.values() |> Enum.sort_by(& &1.name),
      allowed: last(configs, & &1.agents),
      agent: role
    }
  end

  defp plug?(module), do: Code.ensure_loaded?(module) and function_exported?(module, :call, 2)

  # the settings page as a description: limits on the Agents plug; a child
  # with no model of its own runs on the default child model; the reviewer
  # role always on the reviewer model
  defp settings_layer(nil, _role, _model), do: []

  defp settings_layer(settings, role, declared_model) do
    limits =
      {:options, Longx.Agent.Plugs.Agents,
       [max_depth: settings.max_depth, max_children: settings.max_children]}

    {model, effort} =
      cond do
        role == "reviewer" and settings.reviewer_model ->
          {settings.reviewer_model, settings.reviewer_effort}

        role != nil and declared_model == nil and settings.child_model ->
          {settings.child_model, settings.child_effort}

        true ->
          {nil, nil}
      end

    [%Config{ops: [limits], model: model, effort: effort}]
  end

  defp last(configs, fun), do: configs |> Enum.map(fun) |> Enum.reject(&is_nil/1) |> List.last()

  # every declared role, the later layer's declaration replacing the
  # earlier (a local declaration stands in for the shared one); a
  # prompt file that is missing is reported now, not when the role is spawned
  defp roles(layers) do
    Enum.reduce(layers, {%{}, []}, fn %{name: layer, roles: roles}, {acc, errors} ->
      Enum.reduce(roles, {acc, errors}, fn {name, %{config: config, dir: dir}}, {acc, errors} ->
        entry = %{
          name: name,
          summary: config.summary || first_prompt_line(config, dir),
          layer: layer,
          config: config,
          dir: dir
        }

        {Map.put(acc, name, entry), errors ++ missing_prompt_files(config, dir, layer)}
      end)
    end)
  end

  defp missing_prompt_files(%Config{prompt_files: files}, dir, layer) do
    for path <- files, full = Path.expand(path, dir), not File.regular?(full) do
      %{layer: layer, file: full, message: "prompt file #{full}: no such file"}
    end
  end

  defp first_prompt_line(%Config{prompts: [text | _]}, _dir), do: first_line(text)

  defp first_prompt_line(%Config{prompt_files: [path | _]}, dir) do
    case File.read(Path.expand(path, dir)) do
      {:ok, text} -> first_line(text)
      _ -> ""
    end
  end

  defp first_prompt_line(_config, _dir), do: ""

  defp first_line(text),
    do: text |> String.split("\n") |> Enum.find("", &(String.trim(&1) != "")) |> String.trim()

  # a `prompt_file` is prompt text read at load time (relative to the description)
  defp with_prompt_files(configs) do
    Enum.map_reduce(configs, [], fn {%Config{prompt_files: files} = config, dir}, errors ->
      {texts, errors} =
        Enum.map_reduce(files, errors, fn path, errs ->
          full = Path.expand(path, dir)

          case File.read(full) do
            {:ok, text} ->
              {text, errs}

            {:error, reason} ->
              {nil,
               errs ++
                 [
                   %{
                     layer: :project,
                     file: full,
                     message: "prompt file #{full}: #{:file.format_error(reason)}"
                   }
                 ]}
          end
        end)

      {%{config | prompts: config.prompts ++ Enum.reject(texts, &is_nil/1)}, errors}
    end)
  end

  # the growth plug: every project with a .longx — untrusted, it says the shared tree waits
  defp with_local(plugs, project_dir, root, trusted?) do
    if File.dir?(project_dir), do: mount_local(plugs, root, trusted?), else: plugs
  end

  defp mount_local(plugs, root, trusted?) do
    entry = {Local, [root: root, trusted: trusted?]}

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

  defp layer(name, dir, tag, opts \\ []) do
    files = files(name, dir)
    extra = Keyword.get(opts, :extra_defined, [])
    key = {name, dir}

    case __MODULE__.Cache.get(key) do
      %{files: ^files, extra_defined: ^extra} = cached ->
        cached

      previous ->
        loaded = build(name, dir, tag, files, previous, extra)
        __MODULE__.Cache.put(key, loaded)
        loaded
    end
  end

  # where a layer keeps its plugs and its roles
  defp plug_dirs(:project, dir), do: [Path.join(dir, "plugs"), Path.join(dir, "shared/plugs")]
  defp plug_dirs(_name, dir), do: [Path.join(dir, "plugs")]

  @doc false
  def agent_dirs(:project, dir), do: [Path.join(dir, "agents"), Path.join(dir, "shared/agents")]
  def agent_dirs(_name, dir), do: [Path.join(dir, "agents")]

  # every code file of the layer with its mtime (the cache key)
  defp files(name, dir) do
    if File.dir?(dir) do
      descriptions = [Path.join(dir, "agent.exs")]

      plugs =
        Enum.flat_map(plug_dirs(name, dir), &Path.wildcard(Path.join(&1, "**/*.exs")))

      roles =
        Enum.flat_map(agent_dirs(name, dir), fn agents ->
          Path.wildcard(Path.join(agents, "*/agent.exs")) ++
            Path.wildcard(Path.join(agents, "*/plugs/**/*.exs"))
        end)

      (descriptions ++ plugs ++ roles)
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

  defp description?(path), do: Path.basename(path) == "agent.exs"

  defp build(name, dir, tag, files, previous, extra_defined) do
    prefix = @namespace ++ [String.to_atom(tag)]
    plug_files = for {path, _} <- files, not description?(path), do: path

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
    own =
      Enum.uniq(
        Enum.flat_map(sources, fn {_path, ast} -> defined_modules(ast) end) ++
          ((is_map(previous) && previous[:own]) || [])
      )

    # references resolve against this layer's modules and the ones it may see (the shared tree's)
    defined = Enum.uniq(own ++ extra_defined)

    {modules, errors} =
      Enum.reduce(sources, {[], errors}, fn {path, ast}, {mods, errs} ->
        case compile(path, rename(ast, defined, prefix)) do
          {:ok, new} -> {mods ++ new, errs}
          {:error, message} -> {mods, [%{layer: name, file: path, message: message} | errs]}
        end
      end)

    purge(previous, modules)

    {config, errors} =
      case Enum.find(files, fn {path, _} -> path == Path.join(dir, "agent.exs") end) do
        nil -> {nil, errors}
        {path, _} -> evaluate(path, defined, prefix, name, errors)
      end

    # the roles: agents/<name>/agent.exs, each its own description
    {roles, errors} =
      files
      |> Enum.filter(fn {path, _} ->
        description?(path) and path != Path.join(dir, "agent.exs")
      end)
      |> Enum.reduce({%{}, errors}, fn {path, _}, {roles, errs} ->
        role_dir = Path.dirname(path)
        role_name = Path.basename(role_dir)

        case evaluate(path, defined, prefix, name, errs) do
          {%Config{} = c, errs} -> {Map.put(roles, role_name, %{config: c, dir: role_dir}), errs}
          {nil, errs} -> {roles, errs}
        end
      end)

    %{
      name: name,
      dir: dir,
      files: files,
      modules: modules,
      own: own,
      defined: defined,
      extra_defined: extra_defined,
      config: config,
      roles: roles,
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
