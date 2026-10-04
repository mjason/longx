defmodule Longx.Agent.Skills do
  @moduledoc """
  Project-owned Agent Skills files. A snapshot is ordered, path-identified and
  immutable for a turn; the next turn rescans so edits and configuration changes
  cannot leak across sessions. This is data, never executable `.exs` code.

  By default discovers `.agents/skills` from the nearest project marker to cwd.
  Directory links are followed only within the project, canonical files are
  deduplicated, and scanning is bounded. Optional metadata fails open; malformed
  required frontmatter and scan limits are reported, not silently ignored.
  """

  @env_names ~w(HOME PATH PWD USER SHELL TERM TMPDIR LANG CODEX_HOME)

  def snapshot(cwd, opts \\ []) do
    cwd = Path.expand(cwd)
    dirs = search_dirs(cwd, Keyword.get(opts, :root_markers, [".git"]))
    boundary = canonical!(hd(dirs))
    roots = Keyword.get(opts, :roots, Enum.map(dirs, &Path.join(&1, ".agents/skills")))
    disabled = Keyword.get(opts, :disabled, []) |> Enum.map(&Path.expand(&1, cwd))

    limits = %{
      depth: Keyword.get(opts, :max_depth, 6),
      dirs: Keyword.get(opts, :max_dirs, 2_000),
      entries: Keyword.get(opts, :max_entries, 20_000),
      bytes: Keyword.get(opts, :max_file_bytes, 1024 * 1024)
    }

    initial = %{skills: [], warnings: [], seen: MapSet.new()}

    result =
      Enum.reduce(roots, initial, fn root, acc ->
        root = Path.expand(root, cwd)

        {acc, _counts} =
          walk(root, boundary, 0, limits, disabled, acc, %{
            dirs: 0,
            entries: 0,
            seen: MapSet.new()
          })

        acc
      end)

    %{skills: Enum.reverse(result.skills), warnings: Enum.reverse(result.warnings)}
  end

  defp search_dirs(cwd, markers) do
    chain =
      Stream.unfold(cwd, fn
        nil -> nil
        dir -> {dir, if(Path.dirname(dir) == dir, do: nil, else: Path.dirname(dir))}
      end)
      |> Enum.to_list()

    case Enum.find_index(chain, fn dir ->
           Enum.any?(markers, &File.exists?(Path.join(dir, &1)))
         end) do
      nil -> [cwd]
      i -> chain |> Enum.take(i + 1) |> Enum.reverse()
    end
  end

  defp walk(path, boundary, depth, limits, disabled, acc, counts) do
    cond do
      not File.exists?(path) ->
        {acc, counts}

      counts.dirs >= limits.dirs or counts.entries >= limits.entries or depth > limits.depth ->
        {warn(acc, "skill scan limit reached at #{path}"), counts}

      true ->
        case canonical(path) do
          {:ok, real} ->
            cond do
              not inside?(real, boundary) ->
                {warn(acc, "skill path outside project: #{path}"), counts}

              MapSet.member?(counts.seen, real) ->
                {acc, counts}

              true ->
                counts = %{counts | dirs: counts.dirs + 1, seen: MapSet.put(counts.seen, real)}
                acc = load(Path.join(path, "SKILL.md"), boundary, limits, disabled, acc)

                case File.ls(path) do
                  {:ok, entries} ->
                    Enum.reduce(Enum.sort(entries), {acc, counts}, fn entry, {acc, counts} ->
                      if counts.entries >= limits.entries do
                        {warn(acc, "skill scan entry limit reached at #{path}"), counts}
                      else
                        counts = %{counts | entries: counts.entries + 1}
                        child = Path.join(path, entry)

                        if File.dir?(child),
                          do: walk(child, boundary, depth + 1, limits, disabled, acc, counts),
                          else: {acc, counts}
                      end
                    end)

                  {:error, reason} ->
                    {warn(acc, "cannot scan #{path}: #{inspect(reason)}"), counts}
                end
            end

          {:error, reason} ->
            {warn(acc, "cannot resolve #{path}: #{inspect(reason)}"), counts}
        end
    end
  end

  defp load(path, boundary, limits, disabled, acc) do
    if File.regular?(path) do
      with {:ok, real} <- canonical(path),
           true <- inside?(real, boundary),
           false <- MapSet.member?(acc.seen, real),
           {:ok, text} <- bounded_read(real, limits.bytes),
           {:ok, metadata} <- parse(text, Path.basename(Path.dirname(path))) do
        optional =
          optional_metadata(Path.join(Path.dirname(path), "agents/openai.yaml"), boundary)

        enabled = not Enum.any?(disabled, &(&1 == path or canonical(&1) == {:ok, real}))

        entry = %{
          id: real,
          path: path,
          root: Path.dirname(real),
          name: metadata.name,
          description: metadata.description,
          enabled: enabled,
          implicit: get_in(optional, ["policy", "allow_implicit_invocation"]) != false
        }

        %{acc | skills: [entry | acc.skills], seen: MapSet.put(acc.seen, real)}
      else
        true -> acc
        false -> warn(acc, "skill path outside project: #{path}")
        {:error, reason} -> warn(acc, "cannot load #{path}: #{inspect(reason)}")
      end
    else
      acc
    end
  end

  @doc "Parse real YAML frontmatter, with Codex's missing-name fallback."
  def parse(text, fallback) do
    text = String.replace_prefix(text, "\uFEFF", "") |> String.replace("\r\n", "\n")

    with true <- String.valid?(text),
         [_, yaml] <- Regex.run(~r/\A---[ \t]*\n(.*?)\n---[ \t]*(?:\n|\z)/s, text),
         {:ok, map} when is_map(map) <- frontmatter(yaml),
         name when is_binary(name) <- Map.get(map, "name") || fallback,
         description when is_binary(description) <- Map.get(map, "description"),
         name <- if(String.trim(name) == "", do: fallback, else: normalize(name)),
         true <- String.length(name) in 1..64 and String.trim(description) != "" do
      {:ok, %{name: name, description: normalize(description)}}
    else
      _ -> {:error, :invalid_frontmatter}
    end
  rescue
    _ -> {:error, :invalid_frontmatter}
  end

  defp normalize(text), do: text |> String.split() |> Enum.join(" ")

  # Codex compatibility: on YAML failure only, quote unquoted top-level
  # name/description scalars containing ": ". Leave block/quoted values alone.
  defp frontmatter(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, _} = result ->
        result

      {:error, _} ->
        repaired =
          Regex.replace(~r/^(name|description):[ \t]+([^\n]+)$/m, yaml, fn line, key, value ->
            if String.contains?(value, ": ") and
                 not String.starts_with?(value, ["\"", "'", ">", "|", "[", "{"]) do
              key <> ": " <> Jason.encode!(value)
            else
              line
            end
          end)

        YamlElixir.read_from_string(repaired)
    end
  end

  defp optional_metadata(path, boundary) do
    with {:ok, real} <- canonical(path),
         true <- inside?(real, boundary),
         {:ok, text} <- bounded_read(real, 64 * 1024),
         {:ok, map} when is_map(map) <- YamlElixir.read_from_string(text) do
      # Invalid optional policy has no authority over the required skill file.
      if is_map(map["policy"]), do: map, else: %{}
    else
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  @doc "Resolve explicit structured paths first; plain mentions never guess among names."
  def select(snapshot, inputs) do
    explicit = Enum.flat_map(inputs, &Map.get(&1, :skills, []))

    {selected, warnings, named} =
      Enum.reduce(explicit, {[], [], MapSet.new()}, fn choice, {selected, warnings, named} ->
        path = if is_map(choice), do: choice[:path] || choice["path"], else: choice
        entry = Enum.find(snapshot.skills, &(&1.path == path or &1.id == resolved(path)))

        cond do
          entry && entry.enabled ->
            {[entry | selected], warnings, MapSet.put(named, entry.name)}

          entry ->
            {selected, ["skill disabled: #{path}" | warnings], MapSet.put(named, entry.name)}

          true ->
            {selected, ["skill missing: #{inspect(path)}" | warnings], named}
        end
      end)

    mentions =
      inputs
      |> Enum.flat_map(fn input ->
        Regex.scan(~r/(?<![\w$])\$([a-zA-Z0-9][a-zA-Z0-9_-]*)(?![\w])/, Map.get(input, :text, ""),
          capture: :all_but_first
        )
        |> List.flatten()
      end)
      |> Enum.uniq()
      |> Enum.reject(&(&1 in @env_names or MapSet.member?(named, &1)))

    {selected, warnings} =
      Enum.reduce(mentions, {selected, warnings}, fn name, {selected, warnings} ->
        case Enum.filter(snapshot.skills, &(&1.enabled and &1.name == name)) do
          [entry] -> {[entry | selected], warnings}
          [] -> {selected, ["skill missing or disabled: #{name}" | warnings]}
          _ -> {selected, ["skill name ambiguous: #{name}; choose a SKILL.md path" | warnings]}
        end
      end)

    {selected |> Enum.reverse() |> Enum.uniq_by(& &1.id), Enum.reverse(warnings)}
  end

  defp resolved(path) when is_binary(path) do
    case canonical(path) do
      {:ok, real} -> real
      _ -> nil
    end
  end

  defp resolved(_), do: nil

  @doc "Short catalog only; bodies are never eagerly exposed to the model."
  def catalog(snapshot, budget) do
    entries = Enum.filter(snapshot.skills, &(&1.enabled and &1.implicit))

    prefix =
      "## Skills\n\nA skill is a set of local instructions to follow that is stored in a `SKILL.md` file.\n\n### Available skills\n"

    {lines, omitted, _left} =
      Enum.reduce(entries, {[], 0, max(budget - String.length(prefix) - 70, 0)}, fn entry,
                                                                                    {lines,
                                                                                     omitted,
                                                                                     left} ->
        line =
          "- #{entry.name}: #{String.slice(entry.description, 0, 160)} (file: #{entry.path})\n"

        size = String.length(line)

        if size <= left,
          do: {[line | lines], omitted, left - size},
          else: {lines, omitted + 1, left}
      end)

    suffix =
      if omitted > 0,
        do: "\n#{omitted} skills omitted by catalog budget; use skill_list.\n",
        else: ""

    String.slice(prefix <> Enum.join(Enum.reverse(lines)) <> suffix, 0, max(budget, 0))
  end

  @doc "Read a selected instruction fully, or a resource relative to its skill directory."
  def read(entry, resource \\ "SKILL.md") when is_binary(resource) do
    path = Path.expand(resource, entry.root)

    with true <- Path.type(resource) == :relative and inside?(path, entry.root),
         {:ok, real} <- canonical(path),
         true <- inside?(real, entry.root),
         {:ok, text} <- bounded_read(real, 1024 * 1024) do
      {:ok, text}
    else
      false -> {:error, "resource outside skill directory"}
      {:error, reason} -> {:error, "cannot read skill resource: #{inspect(reason)}"}
    end
  end

  # Resolve every component, not only the final symlink. Bound chains and cycles.
  defp canonical(path) do
    [root | parts] = Path.split(Path.expand(path))
    resolve(parts, root, 0)
  end

  defp canonical!(path) do
    {:ok, real} = canonical(path)
    real
  end

  defp resolve(_, _, n) when n > 40, do: {:error, :symlink_loop}
  defp resolve([], acc, _n), do: {:ok, Path.expand(acc)}

  defp resolve([part | rest], acc, n) do
    path = Path.join(acc, part)

    case File.read_link(path) do
      {:ok, target} ->
        expanded = Path.expand(target, Path.dirname(path))
        [root | parts] = Path.split(expanded)
        resolve(parts ++ rest, root, n + 1)

      {:error, :einval} ->
        resolve(rest, path, n)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp inside?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp bounded_read(path, bytes) do
    # Read a bounded amount even if a file grows after stat.
    with {:ok, file} <- File.open(path, [:read, :binary]) do
      try do
        case IO.binread(file, bytes + 1) do
          :eof ->
            {:ok, ""}

          text when is_binary(text) and byte_size(text) <= bytes ->
            if String.valid?(text), do: {:ok, text}, else: {:error, :invalid_utf8}

          text when is_binary(text) ->
            {:error, :file_too_large}

          {:error, reason} ->
            {:error, reason}
        end
      after
        File.close(file)
      end
    end
  end

  defp warn(acc, warning), do: %{acc | warnings: Enum.uniq([warning | acc.warnings])}
end
