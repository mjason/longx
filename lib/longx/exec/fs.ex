defmodule Longx.Exec.Fs do
  @moduledoc """
  codex's `fs/*` requests over the local filesystem, each checked against the
  `Longx.Exec.Policy` of the request first: apply_patch on a remote executor
  writes files through these, so they are a sandbox boundary exactly like a
  command is. Every path is a `file:` URI (`Longx.Exec.PathUri`); results
  are the wire maps; failures are `{code, message}` with codex's own codes
  (`-32004` not found, `-32600` refused, `-32603` the rest).
  """

  alias Longx.Exec.{PathUri, Policy}

  @not_found -32004
  @invalid -32600
  @internal -32603

  @max_walk_depth 64
  @max_walk_directories 10_000
  @max_walk_entries 50_000

  @type result :: {:ok, map} | {:error, {integer, String.t()}}

  @doc "`fs/readFile`."
  @spec read_file(Policy.t(), String.t()) :: result
  def read_file(policy, uri) do
    with {:ok, path} <- allowed(policy, uri, :read),
         {:ok, data} <- io(File.read(path), path) do
      {:ok, %{"dataBase64" => Base.encode64(data)}}
    end
  end

  @doc "`fs/writeFile` (the contents base64)."
  @spec write_file(Policy.t(), String.t(), String.t()) :: result
  def write_file(policy, uri, data_base64) do
    with {:ok, path} <- allowed(policy, uri, :write),
         {:ok, data} <- decode(data_base64),
         {:ok, _} <- io(File.write(path, data), path) do
      {:ok, %{}}
    end
  end

  @doc "`fs/createDirectory`."
  @spec create_directory(Policy.t(), String.t(), boolean) :: result
  def create_directory(policy, uri, recursive?) do
    with {:ok, path} <- allowed(policy, uri, :write),
         {:ok, _} <- io(if(recursive?, do: File.mkdir_p(path), else: File.mkdir(path)), path) do
      {:ok, %{}}
    end
  end

  @doc "`fs/getMetadata`."
  @spec get_metadata(Policy.t(), String.t(), boolean) :: result
  def get_metadata(policy, uri, follow_symlinks?) do
    with {:ok, path} <- allowed(policy, uri, :read),
         {:ok, lstat} <- io(File.lstat(path, time: :posix), path),
         {:ok, stat} <-
           io(if(follow_symlinks?, do: File.stat(path, time: :posix), else: {:ok, lstat}), path) do
      {:ok,
       %{
         "isDirectory" => stat.type == :directory,
         "isFile" => stat.type == :regular,
         "isSymlink" => lstat.type == :symlink,
         "size" => stat.size,
         "createdAtMs" => stat.ctime * 1000,
         "modifiedAtMs" => stat.mtime * 1000
       }}
    end
  end

  @doc "`fs/canonicalize`: symlinks and `..` resolved."
  @spec canonicalize(Policy.t(), String.t()) :: result
  def canonicalize(policy, uri) do
    with {:ok, path} <- allowed(policy, uri, :read),
         {:ok, real} <- real_path(path) do
      {:ok, %{"path" => PathUri.from_path(real)}}
    end
  end

  @doc "`fs/readDirectory`: one level, names only."
  @spec read_directory(Policy.t(), String.t()) :: result
  def read_directory(policy, uri) do
    with {:ok, path} <- allowed(policy, uri, :read),
         {:ok, names} <- io(File.ls(path), path) do
      entries =
        for name <- Enum.sort(names) do
          type = stat_type(Path.join(path, name))
          %{"fileName" => name, "isDirectory" => type == :directory, "isFile" => type == :regular}
        end

      {:ok, %{"entries" => entries}}
    end
  end

  @doc "`fs/remove`."
  @spec remove(Policy.t(), String.t(), boolean, boolean) :: result
  def remove(policy, uri, recursive?, force?) do
    with {:ok, path} <- allowed(policy, uri, :write) do
      case {File.lstat(path), recursive?, force?} do
        {{:error, :enoent}, _, true} ->
          {:ok, %{}}

        {{:error, reason}, _, _} ->
          {:error, error(reason, path)}

        {{:ok, %{type: :directory}}, true, _} ->
          with({:ok, _} <- io(File.rm_rf(path), path), do: {:ok, %{}})

        {{:ok, %{type: :directory}}, false, _} ->
          with(:ok <- io_unit(File.rmdir(path), path), do: {:ok, %{}})

        {{:ok, _}, _, _} ->
          with(:ok <- io_unit(File.rm(path), path), do: {:ok, %{}})
      end
    end
  end

  @doc "`fs/copy`."
  @spec copy(Policy.t(), String.t(), String.t(), boolean) :: result
  def copy(policy, source_uri, destination_uri, recursive?) do
    with {:ok, source} <- allowed(policy, source_uri, :read),
         {:ok, destination} <- allowed(policy, destination_uri, :write) do
      case {File.dir?(source), recursive?} do
        {true, true} ->
          with({:ok, _} <- io(File.cp_r(source, destination), source), do: {:ok, %{}})

        {true, false} ->
          {:error, {@invalid, "#{source} is a directory; copy needs recursive"}}

        {false, _} ->
          with(:ok <- io_unit(File.cp(source, destination), source), do: {:ok, %{}})
      end
    end
  end

  @doc """
  `fs/walk`: breadth-first from a directory, sorted names, symlinks only
  when followed (and only to directories), files and directories only,
  `maxDepth` levels below the root, at most `maxDirectories` opened and
  `maxEntries` looked at (`truncated` past either).
  """
  @spec walk(Policy.t(), String.t(), map) :: result
  def walk(policy, uri, options) do
    limits = %{
      depth: options["maxDepth"] || 0,
      dirs: options["maxDirectories"] || 1,
      entries: options["maxEntries"] || 1,
      follow?: options["followDirectorySymlinks"] || false,
      prune_hidden?: options["pruneHiddenDirectories"] || false
    }

    cond do
      limits.dirs == 0 or limits.entries == 0 ->
        {:error, {@invalid, "filesystem walk limits must be greater than zero"}}

      limits.depth > @max_walk_depth or limits.dirs > @max_walk_directories or
          limits.entries > @max_walk_entries ->
        {:error, {@invalid, "filesystem walk limits exceed maximums"}}

      true ->
        with {:ok, root} <- allowed(policy, uri, :read) do
          case File.lstat(root) do
            {:ok, %{type: type}}
            when type == :directory or (type == :symlink and limits.follow?) ->
              if File.dir?(root),
                do: {:ok, do_walk(root, limits)},
                else: {:ok, %{"entries" => [], "errors" => [], "truncated" => false}}

            {:ok, _} ->
              {:ok, %{"entries" => [], "errors" => [], "truncated" => false}}

            {:error, reason} ->
              {:error, error(reason, root)}
          end
        end
    end
  end

  defp do_walk(root, limits) do
    identity = if limits.follow?, do: elem(real_path(root), 1), else: root

    state = %{
      entries: [],
      errors: [],
      truncated: false,
      seen: %{identity => true},
      dirs: 1,
      count: 0
    }

    result = walk_queue(:queue.from_list([{root, 0}]), limits, state)

    %{
      "entries" => Enum.reverse(result.entries),
      "errors" => Enum.reverse(result.errors),
      "truncated" => result.truncated
    }
  end

  defp walk_queue(queue, limits, state) do
    case :queue.out(queue) do
      {:empty, _} ->
        state

      {{:value, {dir, depth}}, queue} ->
        case File.ls(dir) do
          {:error, reason} ->
            walk_queue(queue, limits, push_error(state, dir, reason))

          {:ok, names} ->
            case walk_entries(Enum.sort(names), dir, depth, queue, limits, state) do
              {:halt, state} -> state
              {:cont, queue, state} -> walk_queue(queue, limits, state)
            end
        end
    end
  end

  defp walk_entries([], _dir, _depth, queue, _limits, state), do: {:cont, queue, state}

  defp walk_entries([name | rest], dir, depth, queue, limits, state) do
    if state.count == limits.entries do
      {:halt, %{state | truncated: true}}
    else
      state = %{state | count: state.count + 1}
      path = Path.join(dir, name)

      case File.lstat(path) do
        {:error, reason} ->
          walk_entries(rest, dir, depth, queue, limits, push_error(state, path, reason))

        {:ok, lstat} ->
          symlink? = lstat.type == :symlink
          type = if symlink?, do: stat_type(path), else: lstat.type

          cond do
            symlink? and (not limits.follow? or type != :directory) ->
              walk_entries(rest, dir, depth, queue, limits, state)

            type not in [:directory, :regular] ->
              walk_entries(rest, dir, depth, queue, limits, state)

            true ->
              kind = if type == :directory, do: "directory", else: "file"

              state = %{
                state
                | entries: [%{"path" => PathUri.from_path(path), "kind" => kind} | state.entries]
              }

              {queue, state} =
                if kind == "directory" and depth < limits.depth and
                     not (limits.prune_hidden? and String.starts_with?(name, ".")),
                   do: enqueue_directory(path, depth, queue, limits, state),
                   else: {queue, state}

              walk_entries(rest, dir, depth, queue, limits, state)
          end
      end
    end
  end

  defp enqueue_directory(path, depth, queue, limits, state) do
    identity = if limits.follow?, do: elem(real_path(path), 1), else: path

    cond do
      Map.has_key?(state.seen, identity) ->
        {queue, state}

      state.dirs == limits.dirs ->
        {queue, %{state | truncated: true, seen: Map.put(state.seen, identity, true)}}

      true ->
        {:queue.in({path, depth + 1}, queue),
         %{state | dirs: state.dirs + 1, seen: Map.put(state.seen, identity, true)}}
    end
  end

  defp push_error(state, path, reason),
    do: %{
      state
      | errors: [
          %{"path" => PathUri.from_path(path), "message" => "#{:file.format_error(reason)}"}
          | state.errors
        ]
    }

  ## helpers

  @doc "The native path of `uri` when the policy allows `mode` on it."
  @spec allowed(Policy.t(), String.t(), :read | :write) ::
          {:ok, Path.t()} | {:error, {integer, String.t()}}
  def allowed(policy, uri, mode) do
    with {:ok, path} <- uri_path(uri) do
      if Policy.allowed?(policy, path, mode),
        do: {:ok, path},
        else: {:error, {@invalid, "sandbox: #{mode} of #{path} is not allowed"}}
    end
  end

  defp uri_path(uri) do
    case PathUri.to_path(uri) do
      {:ok, path} -> {:ok, path}
      {:error, message} -> {:error, {@invalid, message}}
    end
  end

  defp decode(base64) do
    case Base.decode64(base64 || "") do
      {:ok, data} -> {:ok, data}
      :error -> {:error, {@invalid, "dataBase64 is not valid base64"}}
    end
  end

  defp real_path(path), do: {:ok, path |> Path.expand() |> resolve_links(20)}

  # resolve every symlink component (Elixir has no realpath)
  defp resolve_links(path, 0), do: path

  defp resolve_links(path, n) do
    case :file.read_link_all(path) do
      {:ok, target} ->
        resolve_links(Path.expand(to_string(target), Path.dirname(path)), n - 1)

      {:error, _} ->
        parent = Path.dirname(path)

        if parent == path,
          do: path,
          else: Path.join(resolve_links(parent, n), Path.basename(path))
    end
  end

  defp stat_type(path) do
    case File.stat(path) do
      {:ok, %{type: type}} -> type
      {:error, _} -> :other
    end
  end

  defp io({:ok, value}, _path), do: {:ok, value}
  defp io(:ok, _path), do: {:ok, nil}
  defp io({:error, reason}, path), do: {:error, error(reason, path)}
  defp io({:error, reason, _file}, path), do: {:error, error(reason, path)}

  defp io_unit(:ok, _path), do: :ok
  defp io_unit({:error, reason}, path), do: {:error, error(reason, path)}

  defp error(:enoent, path), do: {@not_found, "#{path}: no such file or directory"}

  defp error(reason, path)
       when reason in [:eacces, :eperm, :eisdir, :enotdir, :einval, :eexist, :enotempty],
       do: {@invalid, "#{path}: #{:file.format_error(reason)}"}

  defp error(reason, path), do: {@internal, "#{path}: #{inspect(reason)}"}
end
