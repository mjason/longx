defmodule Longx.Projects.FileRules do
  @moduledoc """
  What Longx ignores in a project — the file watcher skips it, the file tree
  dims it, the @ search leaves it out. Every source is gitignore syntax and
  they stack, the later overriding the earlier (the last matching rule
  decides; `!` means "not ignored"):

    1. ignore — the built-in list (`builtin/0`), the global setting
       (Settings → 文件监控), the project's (`Project.file_rules["ignore"]`)
    2. `.gitignore` — in a git repository: the global excludesfile, `.git/info/exclude`,
       the root's and every deeper one
    3. watch — always watched even when `.gitignore` hides it: built in
       (`.longx/`, `.gitignore`, `.longxignore`), global, the project's
    4. `.longxignore` at the root — above everything: `!target/reports/` brings
       back what `.gitignore` hides

  The matching itself is the shim's (`native/shim/rules.go`, go-git's
  gitignore matcher), for the watcher (`Longx.Projects.Watcher`) and for the
  tree's list (`ignored/1`, `shim ignored`).
  """

  alias Longx.Projects.Project

  @setting "file_rules"

  @builtin_ignore ~w(
    node_modules/ .venv/ venv/ __pycache__/ .pytest_cache/ .mypy_cache/ .ruff_cache/
    _build/ deps/ .elixir_ls/ dist/ build/ target/ .next/ .nuxt/ .cache/ .gradle/ .idea/
    .DS_Store
  )
  @builtin_watch ~w(.longx/ .gitignore .longxignore)

  @type text :: %{ignore: String.t(), watch: String.t()}

  @doc "The built-in lists (the lowest layer; shown on the settings pages)."
  @spec builtin() :: %{ignore: [String.t()], watch: [String.t()]}
  def builtin, do: %{ignore: @builtin_ignore, watch: @builtin_watch}

  @doc "The global layer as saved (two texts, gitignore syntax)."
  @spec global() :: text
  def global do
    case Longx.System.get_setting(@setting) do
      {:ok, %{value: json}} when is_binary(json) ->
        map = Jason.decode!(json)
        %{ignore: map["ignore"] || "", watch: map["watch"] || ""}

      _ ->
        %{ignore: "", watch: ""}
    end
  end

  @doc "Saves the global layer; every open project's watcher reads it."
  @spec put_global(map) :: {:ok, text} | {:error, term}
  def put_global(attrs) do
    current = global()

    merged = %{
      ignore: text(attrs[:ignore] || attrs["ignore"], current.ignore),
      watch: text(attrs[:watch] || attrs["watch"], current.watch)
    }

    with {:ok, _} <- Longx.System.put_setting(@setting, Jason.encode!(merged)) do
      Longx.Projects.Watcher.reload_all()
      {:ok, merged}
    end
  end

  defp text(nil, current), do: current
  defp text(value, _current) when is_binary(value), do: value

  @doc "What the shim is given for a project: the layers the host knows, the root, whether git applies."
  @spec config(Project.t()) :: map
  def config(%Project{root_path: root} = project) do
    global = global()
    own = project.file_rules || %{}
    git? = File.dir?(Path.join(root, ".git")) and Longx.Git.available?()

    %{
      root: root,
      git: git?,
      ignore: @builtin_ignore ++ lines(global.ignore) ++ lines(own_rule(own, :ignore)),
      watch: @builtin_watch ++ lines(global.watch) ++ lines(own_rule(own, :watch)),
      git_global: if(git?, do: Longx.Git.global_excludes(), else: [])
    }
  end

  @doc """
  What the tree dims: an ignored directory whole (`dist/`), one a later `!`
  rule reaches into only itself (`target`, no slash) with what stays ignored
  inside it one by one, ignored files. `shim ignored`, once.
  """
  @spec ignored(Project.t()) :: {:ok, [String.t()]} | {:error, term}
  def ignored(%Project{} = project), do: list("ignored", project, 20_000)

  @doc "The files the rules keep, at most `max` — what the @ search looks through. `shim files`."
  @spec files(Project.t(), pos_integer) :: {:ok, [String.t()]} | {:error, term}
  def files(%Project{} = project, max), do: list("files", project, max)

  defp list(command, project, max) do
    port =
      Port.open({:spawn_executable, Longx.Shim.executable()}, [
        :binary,
        :exit_status,
        :use_stdio,
        args: [command]
      ])

    Port.command(port, Jason.encode!(Map.put(config(project), :max, max)) <> "\n")
    collect(port, command, "")
  end

  defp collect(port, key, acc) do
    receive do
      {^port, {:data, data}} ->
        collect(port, key, acc <> data)

      {^port, {:exit_status, 0}} ->
        case Jason.decode(acc) do
          {:ok, %{^key => list}} -> {:ok, list}
          {:ok, %{"error" => error}} -> {:error, error}
          _ -> {:error, :bad_output}
        end

      {^port, {:exit_status, status}} ->
        {:error, {:exit, status}}
    after
      15_000 ->
        Port.close(port)
        {:error, :timeout}
    end
  end

  # a row read back has string keys, one just written through Elixir may have atoms
  defp own_rule(own, key), do: own[Atom.to_string(key)] || own[key]

  defp lines(nil), do: []

  defp lines(text) when is_binary(text) do
    text
    |> String.split(["\r\n", "\n"])
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
  end
end
