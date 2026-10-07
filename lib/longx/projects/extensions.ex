defmodule Longx.Projects.Extensions do
  @moduledoc """
  The .longx inventory, by object rather than by arbitrary file. Discovery and
  sharing never evaluate code. Artifacts are listed one run directory at a time,
  without recursively reading databases or screenshots.

  Sharing requires a fresh, content-bound preview, moves a whole role, refuses
  symlinks and never replaces a shared object. The top-level local description
  needs a deliberate merge into .longx/agent.exs, not a move into shared/.
  """

  @max_files 200
  @max_bytes 16 * 1024 * 1024
  @text_limit 64 * 1024

  def inventory(root) do
    for layer <- ["local", "shared"],
        item <- layer_items(root, layer),
        do: item
  end

  @doc "One level of an extension/output directory, without following symlinks."
  def list_files(root, path) do
    with true <- String.starts_with?(path, ".longx/") || {:error, "not an extension directory"},
         :ok <- safe(root, path),
         true <- directory?(root, path) || {:error, "not an extension directory"} do
      files =
        for name <- names(root, path),
            child = "#{path}/#{name}",
            :ok == safe(root, child),
            {:ok, stat} <- [File.lstat(Path.join(root, child))],
            stat.type in [:directory, :regular] do
          %{
            name: name,
            path: child,
            kind: if(stat.type == :directory, do: :dir, else: :file),
            size: stat.size
          }
        end

      {:ok, Enum.sort_by(files, &{&1.kind != :dir, &1.name})}
    end
  end

  defp layer_items(root, layer) do
    base = ".longx/#{layer}"

    definitions =
      if layer == "local" and regular?(root, "#{base}/agent.exs"),
        do: [item("definition", layer, "agent.exs", "#{base}/agent.exs", false)],
        else: []

    project_definition =
      if layer == "shared" and regular?(root, ".longx/agent.exs"),
        do: [item("definition", "project", "agent.exs", ".longx/agent.exs", false)],
        else: []

    roles =
      for name <- names(root, "#{base}/agents"),
          directory?(root, "#{base}/agents/#{name}") do
        path = "#{base}/agents/#{name}"
        complete = regular?(root, "#{path}/agent.exs")
        %{item("agents", layer, name, path, layer == "local") | complete: complete}
      end

    scripts =
      for kind <- ["plugs", "watches"],
          name <- names(root, "#{base}/#{kind}"),
          String.ends_with?(name, ".exs"),
          regular?(root, "#{base}/#{kind}/#{name}"),
          do: item(kind, layer, name, "#{base}/#{kind}/#{name}", layer == "local")

    knowledge =
      for topic <- names(root, "#{base}/knowledge"),
          directory?(root, "#{base}/knowledge/#{topic}"),
          name <- names(root, "#{base}/knowledge/#{topic}"),
          String.ends_with?(name, ".md"),
          regular?(root, "#{base}/knowledge/#{topic}/#{name}"),
          do:
            item(
              "knowledge",
              layer,
              "#{topic}/#{name}",
              "#{base}/knowledge/#{topic}/#{name}",
              layer == "local"
            )

    artifacts =
      if layer == "local" do
        for bucket <- names(root, "#{base}/artifacts"),
            path <- artifact_runs(root, "#{base}/artifacts/#{bucket}"),
            do: item("artifacts", layer, Path.basename(path), path, false)
      else
        []
      end

    definitions ++ project_definition ++ roles ++ scripts ++ knowledge ++ artifacts
  end

  defp artifact_runs(root, path) do
    runs =
      for name <- names(root, path),
          String.starts_with?(name, "run-"),
          directory?(root, "#{path}/#{name}"),
          do: "#{path}/#{name}"

    if runs == [] and directory?(root, path), do: [path], else: runs
  end

  defp item(kind, layer, name, path, shareable) do
    %{
      kind: kind,
      layer: layer,
      name: name,
      path: path,
      shareable: shareable,
      complete: true
    }
  end

  # Compatibility for the old definition view: candidates only, not artifacts.
  def local_files(root) do
    inventory(root)
    |> Enum.filter(&(&1.layer == "local" and &1.kind != "artifacts"))
    |> Enum.flat_map(fn
      %{kind: "agents", path: path} ->
        for name <- ["agent.exs", "prompt.md"],
            regular?(root, "#{path}/#{name}"),
            do: String.replace_prefix("#{path}/#{name}", ".longx/local/", "")

      %{path: path} ->
        [String.replace_prefix(path, ".longx/local/", "")]
    end)
    |> Enum.sort()
  end

  def preview(root, relative) do
    with {:ok, path, kind} <- share_path(relative),
         from = ".longx/local/#{path}",
         to = ".longx/shared/#{path}",
         :ok <- safe(root, from),
         :ok <- safe(root, to),
         {:ok, files} <- collect(root, from),
         true <- files != [] || {:error, "the local object has no files"},
         :ok <- valid_role(kind, files, from),
         {:ok, entries} <- preview_entries(root, from, to, files) do
      conflicts = if exists?(root, to), do: [to], else: []

      digest =
        :crypto.hash(:sha256, :erlang.term_to_binary({path, entries, conflicts}))
        |> Base.encode16(case: :lower)

      {:ok,
       %{
         path: path,
         target: to,
         digest: digest,
         files: entries,
         conflicts: conflicts,
         can_share: conflicts == []
       }}
    else
      false -> {:error, "invalid local object"}
      {:error, _} = error -> error
    end
  end

  def promote(root, relative, expected_digest) do
    :global.trans({{__MODULE__, Path.expand(root)}, self()}, fn ->
      with {:ok, preview} <- preview(root, relative),
           true <-
             (is_binary(expected_digest) and preview.digest == expected_digest) ||
               {:error, "the object changed or has not been reviewed; preview it again"},
           true <-
             preview.can_share || {:error, "a shared object already exists; nothing replaced"},
           from = Path.join(root, ".longx/local/#{preview.path}"),
           to = Path.join(root, preview.target),
           :ok <- File.mkdir_p(Path.dirname(to)),
           :ok <- safe(root, preview.target),
           :ok <- move_without_replace(from, to) do
        {:ok, String.replace_prefix(preview.target, ".longx/", "")}
      end
    end)
  end

  defp move_without_replace(from, to) do
    if File.dir?(from) do
      # Reserve an empty target atomically: rename may only replace this empty
      # directory, never an existing role (or a racing writer's nonempty role).
      with :ok <- File.mkdir(to) do
        case File.rename(from, to) do
          :ok ->
            :ok

          {:error, reason} ->
            File.rmdir(to)
            {:error, "cannot share role: #{:file.format_error(reason)}"}
        end
      else
        {:error, reason} -> {:error, "cannot reserve shared role: #{:file.format_error(reason)}"}
      end
    else
      # Exclusive creation prevents rename's silent replacement of shared files.
      with {:ok, content} <- File.read(from),
           {:ok, io} <- File.open(to, [:write, :binary, :exclusive]) do
        result =
          try do
            IO.binwrite(io, content)
          rescue
            error -> {:error, Exception.message(error)}
          end

        closed = File.close(io)

        case {result, closed} do
          {:ok, :ok} ->
            case File.read(from) do
              {:ok, ^content} -> File.rm(from)
              _ -> {:error, :source_changed}
            end

          {{:error, _} = error, _} ->
            error

          {_, {:error, _} = error} ->
            error
        end
        |> case do
          :ok ->
            :ok

          {:error, reason} ->
            File.rm(to)
            {:error, "cannot share file: #{inspect(reason)}"}
        end
      else
        {:error, reason} -> {:error, "cannot create shared file: #{:file.format_error(reason)}"}
      end
    end
  end

  defp share_path(relative) do
    parts = Path.split(relative)

    cond do
      Path.type(relative) != :relative or Enum.any?(parts, &(&1 in [".", ".."])) ->
        {:error, "invalid path"}

      match?(["agents", _], parts) ->
        {:ok, relative, "agents"}

      match?(["agents", _, "agent.exs"], parts) ->
        {:ok, Path.dirname(relative), "agents"}

      match?([kind, _] when kind in ["plugs", "watches"], parts) and
          Path.extname(relative) == ".exs" ->
        {:ok, relative, hd(parts)}

      match?(["knowledge", _, _], parts) and Path.extname(relative) == ".md" ->
        {:ok, relative, "knowledge"}

      true ->
        {:error,
         "only roles, plugs, watches and knowledge can be shared; review definitions separately"}
    end
  end

  defp valid_role("agents", files, from) do
    if Enum.any?(files, &(&1.path == "#{from}/agent.exs")),
      do: :ok,
      else: {:error, "role is missing agent.exs"}
  end

  defp valid_role(_, _, _), do: :ok

  defp collect(root, path), do: collect(root, [path], [], 0)

  defp collect(_root, pending, acc, bytes)
       when length(acc) > @max_files or length(pending) > @max_files or bytes > @max_bytes,
       do: {:error, "object is too large to review (200 files / 16 MiB)"}

  defp collect(_root, [], acc, _bytes), do: {:ok, Enum.sort_by(acc, & &1.path)}

  defp collect(root, [path | rest], acc, bytes) do
    with :ok <- safe(root, path),
         {:ok, stat} <- File.lstat(Path.join(root, path)) do
      case stat.type do
        :directory ->
          with {:ok, entries} <- File.ls(Path.join(root, path)) do
            collect(root, Enum.map(entries, &"#{path}/#{&1}") ++ rest, acc, bytes)
          end

        :regular ->
          collect(root, rest, [%{path: path, size: stat.size} | acc], bytes + stat.size)

        _ ->
          {:error, "only regular files and directories can be shared"}
      end
    else
      {:error, reason} -> {:error, "cannot review local object: #{inspect(reason)}"}
    end
  end

  defp preview_entries(root, from, to, files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
      target = to <> String.replace_prefix(file.path, from, "")

      with :ok <- safe(root, target),
           {:ok, content} <- bounded_read(Path.join(root, file.path), file.size) do
        text? = String.valid?(content) and not String.contains?(content, <<0>>)

        entry = %{
          source: file.path,
          target: target,
          size: file.size,
          hash: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower),
          content: if(text? and byte_size(content) <= @text_limit, do: content, else: nil),
          truncated: byte_size(content) > @text_limit,
          binary: not text?
        }

        {:cont, {:ok, acc ++ [entry]}}
      else
        {:error, reason} -> {:halt, {:error, "cannot review file: #{inspect(reason)}"}}
      end
    end)
  end

  defp bounded_read(path, size) do
    File.open(path, [:read, :binary], fn io ->
      case IO.binread(io, size + 1) do
        :eof when size == 0 -> {:ok, ""}
        content when is_binary(content) and byte_size(content) == size -> {:ok, content}
        _ -> {:error, :source_changed}
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, _} = error -> error
    end
  end

  defp safe(root, path) do
    full = Path.expand(path, root)
    expanded_root = Path.expand(root)

    if Path.type(path) == :relative and
         not Enum.any?(Path.split(path), &(&1 in [".", ".."])) and
         String.starts_with?(full, expanded_root <> "/") do
      path
      |> Path.split()
      |> Enum.reduce_while(expanded_root, fn part, parent ->
        next = Path.join(parent, part)

        case File.lstat(next) do
          {:ok, %{type: :symlink}} -> {:halt, {:error, "symlinks are not allowed"}}
          {:ok, _} -> {:cont, next}
          {:error, :enoent} -> {:cont, next}
          {:error, reason} -> {:halt, {:error, inspect(reason)}}
        end
      end)
      |> case do
        {:error, _} = error -> error
        _ -> :ok
      end
    else
      {:error, "path is outside the project"}
    end
  end

  defp names(root, path) do
    with :ok <- safe(root, path),
         {:ok, names} <- File.ls(Path.join(root, path)),
         do: Enum.sort(names),
         else: (_ -> [])
  end

  defp regular?(root, path), do: type?(root, path, :regular)
  defp directory?(root, path), do: type?(root, path, :directory)

  defp type?(root, path, type) do
    with :ok <- safe(root, path),
         {:ok, %{type: ^type}} <- File.lstat(Path.join(root, path)),
         do: true,
         else: (_ -> false)
  end

  defp exists?(root, path), do: File.exists?(Path.join(root, path))
end
