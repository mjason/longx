defmodule Longx.Projects.Workspace do
  @moduledoc """
  The project's files as the file tree and the editor see them. Every path
  is relative to the project root and resolved inside it — `..`, absolute
  paths and anything escaping the root are refused, `.git` is never listed
  or touched. Files are read up to `@read_limit` bytes; a file with a NUL
  byte or invalid UTF-8 in its head is reported binary and not loaded.
  """

  @read_limit 1_000_000
  @sniff 8_192

  @type kind :: :file | :dir
  @type entry :: %{name: String.t(), path: String.t(), kind: kind, size: non_neg_integer}
  @type file :: %{
          path: String.t(),
          content: String.t() | nil,
          size: non_neg_integer,
          binary: boolean,
          truncated: boolean
        }
  @type error ::
          :outside_root | :not_found | :not_a_file | :not_a_directory | :exists | File.posix()

  @doc "One level of the tree: directories first, then files, both by name; `.git` hidden."
  @spec list(Path.t(), String.t()) :: {:ok, [entry]} | {:error, error}
  def list(root, rel) do
    with {:ok, dir} <- resolve(root, rel),
         {:ok, names} <- ls(dir) do
      entries =
        names
        |> Enum.reject(&(rel == "" and &1 == ".git"))
        |> Enum.map(&entry(root, dir, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(&{if(&1.kind == :dir, do: 0, else: 1), String.downcase(&1.name)})

      {:ok, entries}
    end
  end

  defp ls(dir) do
    cond do
      not File.exists?(dir) -> {:error, :not_found}
      not File.dir?(dir) -> {:error, :not_a_directory}
      true -> File.ls(dir)
    end
  end

  defp entry(root, dir, name) do
    full = Path.join(dir, name)

    case File.stat(full) do
      {:ok, %File.Stat{type: :directory}} ->
        %{name: name, path: Path.relative_to(full, root), kind: :dir, size: 0}

      {:ok, %File.Stat{type: :regular, size: size}} ->
        %{name: name, path: Path.relative_to(full, root), kind: :file, size: size}

      _ ->
        nil
    end
  end

  @doc "A file's text (up to 1 MB; `truncated` past that), or `binary: true` with no content."
  @spec read(Path.t(), String.t()) :: {:ok, file} | {:error, error}
  def read(root, rel) do
    with {:ok, full} <- resolve(root, rel),
         {:ok, %File.Stat{type: :regular, size: size}} <- stat(full),
         {:ok, head} <- read_head(full) do
      if binary?(head) do
        {:ok, %{path: rel, content: nil, size: size, binary: true, truncated: false}}
      else
        content =
          if size > @read_limit,
            do: full |> read_bytes(@read_limit) |> trim_partial_utf8(),
            else: File.read!(full)

        {:ok,
         %{path: rel, content: content, size: size, binary: false, truncated: size > @read_limit}}
      end
    end
  end

  defp stat(full) do
    case File.stat(full) do
      {:ok, %File.Stat{type: :regular}} = ok -> ok
      {:ok, _} -> {:error, :not_a_file}
      {:error, :enoent} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp read_head(full), do: {:ok, read_bytes(full, @sniff)}

  defp read_bytes(full, n) do
    File.open!(full, [:read, :binary], fn io ->
      case IO.binread(io, n) do
        data when is_binary(data) -> data
        _ -> ""
      end
    end)
  end

  # a cut of the file (the sniff, the 1 MB cap) may end inside a character —
  # a Chinese document is not a binary for that: the cut is judged without
  # the partial character at its end
  defp binary?(head),
    do: String.contains?(head, <<0>>) or not String.valid?(trim_partial_utf8(head))

  @doc false
  # drops an incomplete UTF-8 sequence at the very end (up to three bytes)
  def trim_partial_utf8(bytes) when is_binary(bytes) do
    Enum.find_value(0..3, bytes, fn drop ->
      size = byte_size(bytes) - drop

      if size >= 0 do
        candidate = binary_part(bytes, 0, size)
        if String.valid?(candidate), do: candidate
      end
    end)
  end

  @doc "Writes the file (created when missing; its directory must exist)."
  @spec write(Path.t(), String.t(), String.t()) :: :ok | {:error, error}
  def write(root, rel, content) do
    with {:ok, full} <- resolve(root, rel) do
      cond do
        not File.dir?(Path.dirname(full)) -> {:error, :not_found}
        File.dir?(full) -> {:error, :not_a_file}
        true -> File.write(full, content)
      end
    end
  end

  @doc "A new empty file or directory; refuses an existing path."
  @spec create(Path.t(), String.t(), kind) :: {:ok, entry} | {:error, error}
  def create(root, rel, kind) do
    with {:ok, full} <- resolve(root, rel),
         :ok <- absent(full),
         :ok <- if(kind == :dir, do: File.mkdir_p(full), else: touch(full)) do
      {:ok, entry(root, Path.dirname(full), Path.basename(full))}
    end
  end

  defp touch(full) do
    with :ok <- File.mkdir_p(Path.dirname(full)), do: File.write(full, "")
  end

  @doc "Moves / renames inside the root; refuses to overwrite."
  @spec rename(Path.t(), String.t(), String.t()) :: {:ok, entry} | {:error, error}
  def rename(root, from, to) do
    with {:ok, src} <- resolve(root, from),
         {:ok, dst} <- resolve(root, to),
         :ok <- present(src),
         :ok <- absent(dst),
         :ok <- File.mkdir_p(Path.dirname(dst)),
         :ok <- File.rename(src, dst) do
      {:ok, entry(root, Path.dirname(dst), Path.basename(dst))}
    end
  end

  @doc "Removes a file or a whole directory. Never the root, never `.git`."
  @spec delete(Path.t(), String.t()) :: :ok | {:error, error}
  def delete(root, rel) do
    with {:ok, full} <- resolve(root, rel),
         :ok <-
           if(full == Path.expand(root) or rel == ".git", do: {:error, :outside_root}, else: :ok),
         :ok <- present(full),
         {:ok, _} <- File.rm_rf(full) do
      :ok
    end
  end

  defp present(full), do: if(File.exists?(full), do: :ok, else: {:error, :not_found})
  defp absent(full), do: if(File.exists?(full), do: {:error, :exists}, else: :ok)

  @doc "The absolute path for a relative one, provided it stays inside the root."
  @spec resolve(Path.t(), String.t()) :: {:ok, Path.t()} | {:error, :outside_root}
  def resolve(root, rel) do
    root = Path.expand(root)
    full = Path.expand(rel, root)

    cond do
      Path.type(rel) == :absolute -> {:error, :outside_root}
      full == root -> {:ok, full}
      String.starts_with?(full, root <> "/") and not git_internal?(full, root) -> {:ok, full}
      true -> {:error, :outside_root}
    end
  end

  defp git_internal?(full, root), do: String.starts_with?(full, Path.join(root, ".git") <> "/")
end
