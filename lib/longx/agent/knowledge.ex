defmodule Longx.Agent.Knowledge do
  @moduledoc """
  Knowledge is markdown files with front matter, in three roots:

    * `longx` — shipped with Longx (`priv/agent/knowledge/`), read-only:
      how to write plugs, the description format and its versions;
    * `global` — the person's, every project (`<data>/agent/knowledge/`),
      a git repository of its own where every write is a commit;
    * `project` — the project's (`<root>/.longx/knowledge/`), committed
      with the code by the turn's own bookmarks.

  A doc names itself in its front matter (`title`, `summary`, `tags`,
  `always: true` for what every turn must know); a file without one is
  titled by its name and summarised by its first line. Paths are
  `<root>/<relative>` (`project/ops/deploy.md`). `docs/1` lists, `read/2`
  gives a body, `search/2` finds lines, `write/3` creates or replaces a
  doc (front matter required; the shipped root refuses).
  """

  alias Longx.Git

  @type doc :: %{
          root: :longx | :global | :project,
          path: String.t(),
          file: Path.t(),
          title: String.t(),
          summary: String.t(),
          tags: [String.t()],
          always?: boolean,
          body: String.t()
        }

  @roots [:longx, :global, :project]

  @doc "The directories of the roots for a working directory."
  @spec roots(Path.t()) :: %{longx: Path.t(), global: Path.t(), project: Path.t()}
  def roots(cwd) do
    %{
      longx: Path.join(:code.priv_dir(:longx), "agent/knowledge"),
      global: Path.join(Longx.Agent.Loader.global_dir(), "knowledge"),
      project: Path.join(cwd, ".longx/knowledge")
    }
  end

  @doc "Every doc of the given roots (all by default), shipped first, then global, then project."
  @spec docs(Path.t(), [atom]) :: [doc]
  def docs(cwd, which \\ @roots) do
    dirs = roots(cwd)

    for root <- @roots,
        root in which,
        dir = dirs[root],
        File.dir?(dir),
        file <- dir |> Path.join("**/*.md") |> Path.wildcard() |> Enum.sort(),
        do: parse(root, Path.relative_to(file, dir), file)
  end

  defp parse(root, rel, file) do
    text = File.read!(file)
    {front, body} = split_front_matter(text)
    stem = rel |> Path.basename(".md")

    %{
      root: root,
      path: "#{root}/#{rel}",
      file: file,
      title: front["title"] || stem,
      summary: front["summary"] || first_line(body),
      tags: List.wrap(front["tags"]),
      always?: front["always"] == true,
      body: body
    }
  end

  @doc "The front matter (a map) and the body of a markdown text."
  @spec split_front_matter(String.t()) :: {map, String.t()}
  def split_front_matter("---\n" <> rest) do
    case String.split(rest, "\n---\n", parts: 2) do
      [front, body] -> {parse_front(front), String.trim_leading(body, "\n")}
      _ -> {%{}, "---\n" <> rest}
    end
  end

  def split_front_matter(text), do: {%{}, text}

  # the YAML subset a doc needs: `key: value`, `tags: [a, b]`, true / false
  defp parse_front(text) do
    text
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [key, value] -> Map.put(acc, String.trim(key), front_value(String.trim(value)))
        _ -> acc
      end
    end)
  end

  defp front_value("true"), do: true
  defp front_value("false"), do: false

  defp front_value("[" <> rest) do
    rest
    |> String.trim_trailing("]")
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp front_value(value), do: String.trim(value, "\"")

  defp first_line(body) do
    body
    |> String.split("\n")
    |> Enum.find("", &(String.trim(&1) != ""))
    |> String.trim()
    |> String.slice(0, 160)
  end

  @doc "The body of one doc."
  @spec read(Path.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def read(cwd, path) do
    with {:ok, _root, file} <- locate(cwd, path),
         {:ok, text} <- File.read(file) do
      {_front, body} = split_front_matter(text)
      {:ok, body}
    else
      {:error, :enoent} ->
        {:error, "no knowledge at #{path}"}

      {:error, reason} when is_atom(reason) ->
        {:error, "cannot read #{path}: #{:file.format_error(reason)}"}

      {:error, message} ->
        {:error, message}
    end
  end

  @doc "Lines (title and summary included) containing every word of the query, at most 50."
  @spec search(Path.t(), String.t()) :: [%{path: String.t(), line: pos_integer, text: String.t()}]
  def search(cwd, query) do
    words = query |> String.downcase() |> String.split(~r/\s+/, trim: true)

    if words == [] do
      []
    else
      cwd
      |> docs()
      |> Enum.flat_map(fn doc ->
        head = ["#{doc.title} — #{doc.summary}"]

        (head ++ String.split(doc.body, "\n"))
        |> Enum.with_index()
        |> Enum.filter(fn {line, _} ->
          down = String.downcase(line)
          Enum.all?(words, &String.contains?(down, &1))
        end)
        |> Enum.map(fn {line, i} -> %{path: doc.path, line: i, text: String.trim(line)} end)
      end)
      |> Enum.take(50)
    end
  end

  @doc """
  Creates or replaces a doc. The content must start with front matter
  naming `title` and `summary`; `longx/…` is read-only; the global root
  commits every write.
  """
  @spec write(Path.t(), String.t(), String.t()) :: {:ok, Path.t()} | {:error, String.t()}
  def write(cwd, path, content) do
    with {:ok, root, file} <- locate(cwd, path),
         :ok <- writable(root),
         :ok <- well_formed(content),
         :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.write(file, content),
         :ok <- commit(root, roots(cwd)[root], path) do
      {:ok, file}
    else
      {:error, reason} when is_atom(reason) ->
        {:error, "cannot write #{path}: #{:file.format_error(reason)}"}

      {:error, message} ->
        {:error, message}
    end
  end

  defp locate(cwd, path) do
    case String.split(path, "/", parts: 2) do
      [root, rel] when root in ["longx", "global", "project"] and rel != "" ->
        root = String.to_existing_atom(root)
        dir = roots(cwd)[root]
        file = Path.expand(rel, dir)

        if String.starts_with?(file, dir <> "/") and Path.extname(file) == ".md",
          do: {:ok, root, file},
          else: {:error, "#{path} must be a .md file inside its root"}

      _ ->
        {:error,
         "#{path}: a knowledge path is <root>/<file>.md with root longx, global or project"}
    end
  end

  defp writable(:longx), do: {:error, "the longx root is read-only (it ships with Longx)"}
  defp writable(_root), do: :ok

  defp well_formed(content) do
    case split_front_matter(content) do
      {%{"title" => t, "summary" => s}, _}
      when is_binary(t) and is_binary(s) and t != "" and s != "" ->
        :ok

      _ ->
        {:error, "the content must start with front matter (--- title: … summary: … ---)"}
    end
  end

  # the global root is a repository: a commit per write, one at a time
  defp commit(:global, dir, path) do
    :global.trans(
      {{__MODULE__, dir}, self()},
      fn ->
        with :ok <- if(Git.repository?(dir), do: :ok, else: Git.init(dir)),
             {:ok, _} <- Git.commit_all(dir, "knowledge: #{path}"),
             do: :ok
      end,
      [node()],
      :infinity
    )
    |> case do
      :ok -> :ok
      {:error, reason} -> {:error, "cannot commit #{path}: #{inspect(reason)}"}
      :aborted -> {:error, "cannot commit #{path}: the knowledge repository is busy"}
    end
  end

  defp commit(_root, _dir, _path), do: :ok
end
