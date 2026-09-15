defmodule Longx.Exec.Discovery do
  @moduledoc """
  codex's `capabilityRoots/discoverV1`: for each root it names (the cwd,
  the workspace roots), the skills (`SKILL.md` files, with their
  `agents/openai.yaml`), the root's plugin manifest (`.codex-plugin/`,
  `.claude-plugin/`, `.cursor-plugin/plugin.json`, with its `.mcp.json`)
  and every plugin manifest below the root as a namespace — read through
  `Longx.Exec.Fs`, so the request's sandbox policy applies. A file that
  cannot be read is a warning, a root that is not a directory an error on
  that root; codex's scan limits (depth 6, 2 000 directories, 20 000
  entries, 1 MiB per file, 16 MiB per root) are kept.
  """

  alias Longx.Exec.{Fs, PathUri, Policy}

  @manifest_dirs [".codex-plugin", ".claude-plugin", ".cursor-plugin"]
  @skill_file "SKILL.md"
  @skill_metadata "agents/openai.yaml"
  @mcp_config ".mcp.json"
  @max_file_bytes 1024 * 1024
  @max_bundle_bytes 16 * 1024 * 1024
  @walk %{
    "maxDepth" => 6,
    "maxDirectories" => 2_000,
    "maxEntries" => 20_000,
    "followDirectorySymlinks" => true,
    "pruneHiddenDirectories" => false
  }

  @doc "The discovery of every requested root (`%{\"id\", \"path\", \"sandbox\"}` maps)."
  @spec discover(Policy.t(), [map]) :: map
  def discover(policy, roots), do: %{"roots" => Enum.map(roots, &root(policy, &1))}

  defp root(policy, %{"id" => id, "path" => uri}) do
    base = %{
      "id" => id,
      "path" => uri,
      "plugin" => nil,
      "skills" => [],
      "namespaceManifests" => [],
      "warnings" => [],
      "error" => nil
    }

    with {:ok, %{"isDirectory" => true}} <- directory(policy, uri),
         {:ok, walk} <- Fs.walk(policy, uri, @walk) do
      warnings =
        for(
          %{"path" => p, "message" => m} <- walk["errors"],
          do: "failed to scan capability path #{p}: #{m}"
        ) ++
          if(walk["truncated"],
            do: ["capability scan reached its traversal limit (root: #{uri})"],
            else: []
          )

      files = for %{"kind" => "file", "path" => p} <- walk["entries"], do: p
      budget = %{bytes: 0, warnings: warnings}
      {root_manifest, budget} = root_manifest(policy, uri, budget)

      {ancestor, budget} =
        if(root_manifest, do: {nil, budget}, else: ancestor_manifest(policy, uri, budget))

      {namespaces, budget} = namespaces(policy, files, root_manifest || ancestor, budget)
      {plugin, budget} = plugin(policy, uri, root_manifest, budget)
      {skills, budget} = skills(policy, files, budget)

      %{
        base
        | "plugin" => plugin,
          "skills" => skills,
          "namespaceManifests" => namespaces,
          "warnings" => budget.warnings
      }
    else
      {:ok, _} ->
        %{base | "error" => "capability root #{uri} is not a directory"}

      {:error, {_code, message}} ->
        %{base | "error" => "failed to inspect capability root #{uri}: #{message}"}
    end
  end

  defp directory(policy, uri), do: Fs.get_metadata(policy, uri, true)

  defp root_manifest(policy, root_uri, budget) do
    Enum.reduce_while(@manifest_dirs, {nil, budget}, fn dir, {nil, budget} ->
      case read(policy, join(root_uri, "#{dir}/plugin.json"), budget) do
        {nil, budget} -> {:cont, {nil, budget}}
        {file, budget} -> {:halt, {file, budget}}
      end
    end)
  end

  # a nested root belongs to the nearest plugin above it
  defp ancestor_manifest(policy, root_uri, budget) do
    {:ok, path} = PathUri.to_path(root_uri)

    path
    |> Path.dirname()
    |> ancestors()
    |> Enum.reduce_while({nil, budget}, fn dir, {nil, budget} ->
      case root_manifest(policy, PathUri.from_path(dir), budget) do
        {nil, budget} -> {:cont, {nil, budget}}
        found -> {:halt, found}
      end
    end)
  end

  defp ancestors("/"), do: ["/"]
  defp ancestors(dir), do: [dir | ancestors(Path.dirname(dir))]

  defp namespaces(policy, files, inherited, budget) do
    {seen, acc} =
      case inherited do
        nil -> {%{}, []}
        %{"path" => p} = file -> {%{plugin_root(p) => true}, [file]}
      end

    manifests =
      files
      |> Enum.filter(&manifest?/1)
      |> Enum.sort_by(&{plugin_root(&1), manifest_priority(&1)})

    {acc, _seen, budget} =
      Enum.reduce(manifests, {acc, seen, budget}, fn uri, {acc, seen, budget} ->
        root = plugin_root(uri)

        if Map.has_key?(seen, root) do
          {acc, seen, budget}
        else
          case read(policy, uri, budget) do
            {nil, budget} -> {acc, Map.put(seen, root, true), budget}
            {file, budget} -> {[file | acc], Map.put(seen, root, true), budget}
          end
        end
      end)

    {Enum.reverse(acc), budget}
  end

  defp plugin(_policy, _root_uri, nil, budget), do: {nil, budget}

  defp plugin(policy, root_uri, manifest, budget) do
    {mcp, budget} = read(policy, join(root_uri, @mcp_config), budget)
    {%{"manifest" => manifest, "mcpConfig" => mcp, "appsConfig" => nil}, budget}
  end

  defp skills(policy, files, budget) do
    files
    |> Enum.filter(&(basename(&1) == @skill_file))
    |> Enum.sort()
    |> Enum.reduce({[], budget}, fn uri, {acc, budget} ->
      case read(policy, uri, budget) do
        {nil, budget} ->
          {acc, budget}

        {instructions, budget} ->
          {metadata, budget} = read(policy, join(parent(uri), @skill_metadata), budget)
          {[%{"instructions" => instructions, "metadata" => metadata} | acc], budget}
      end
    end)
    |> then(fn {acc, budget} -> {Enum.reverse(acc), budget} end)
  end

  # a text file within the budgets, or nil with a warning when it cannot be read
  defp read(policy, uri, budget) do
    case Fs.read_file(policy, uri) do
      {:ok, %{"dataBase64" => data}} ->
        contents = Base.decode64!(data)

        cond do
          byte_size(contents) > @max_file_bytes ->
            {nil, warn(budget, "capability file #{uri} exceeds #{@max_file_bytes} bytes")}

          budget.bytes + byte_size(contents) > @max_bundle_bytes ->
            {nil, warn(budget, "capability bundle budget exhausted at #{uri}")}

          not String.valid?(contents) ->
            {nil, warn(budget, "capability file #{uri} is not valid UTF-8")}

          true ->
            {%{"path" => uri, "contents" => contents},
             %{budget | bytes: budget.bytes + byte_size(contents)}}
        end

      {:error, {-32004, _}} ->
        {nil, budget}

      {:error, {_code, message}} ->
        {nil, warn(budget, "failed to read capability file #{uri}: #{message}")}
    end
  end

  defp warn(budget, message), do: %{budget | warnings: budget.warnings ++ [message]}

  defp manifest?(uri), do: manifest_priority(uri) != nil

  defp manifest_priority(uri) do
    if basename(uri) == "plugin.json",
      do: Enum.find_index(@manifest_dirs, &(&1 == basename(parent(uri)))),
      else: nil
  end

  defp plugin_root(uri), do: uri |> parent() |> parent()

  defp basename(uri), do: uri |> String.split("/") |> List.last() |> URI.decode()
  defp parent(uri), do: uri |> String.split("/") |> Enum.drop(-1) |> Enum.join("/")

  defp join(uri, relative),
    do:
      uri <>
        "/" <>
        (relative
         |> String.split("/")
         |> Enum.map_join("/", &URI.encode(&1, fn c -> URI.char_unreserved?(c) end)))
end
