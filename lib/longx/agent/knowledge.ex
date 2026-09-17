defmodule Longx.Agent.Knowledge do
  @moduledoc """
  Knowledge is markdown files with front matter, in four roots:

    * `longx` — shipped with Longx (`priv/agent/knowledge/`), read-only:
      how to write plugs, the description format and its versions;
    * `global` — the person's, every project (`<data>/agent/knowledge/`) —
      the one thing at the global level; a git repository of its own where
      every write is a commit, when the machine has git;
    * `project` — the project's shared tree (`<root>/.longx/shared/knowledge/`;
      the flat `.longx/knowledge/` of before is read too), committed with
      the code by the turn's own bookmarks — what a person reviewed;
    * `local` — `<root>/.longx/local/knowledge/`, gitignored: this
      machine's and the agent's own notes, where it writes by default.

  **Two levels**: a doc lives in a topic — `<root>/<topic>/<name>.md` — so
  the index folds to one line per topic (a `README.md` in the topic speaks
  for it) and a topic reads as the list of its docs (`read/2` with
  `project/deploy`). A doc names itself in its front matter (`title`,
  `summary`, `tags`, `always: true` for what every turn must know); a
  file without one is titled by its name and summarised by its first
  line. `docs/1` lists, `read/2` gives a body or a topic, `search/2`
  finds lines, `write/3` creates or replaces a doc (front matter and a
  topic required; the shipped root refuses; a local write keeps `local/`
  gitignored), `promote/2` moves a local doc into the shared tree.
  """

  alias Longx.Git

  @type doc :: %{
          root: :longx | :global | :project | :local,
          path: String.t(),
          file: Path.t(),
          title: String.t(),
          summary: String.t(),
          tags: [String.t()],
          always?: boolean,
          body: String.t()
        }

  @roots [:longx, :global, :project, :local]

  @doc "The directory each root is written to, for a working directory."
  @spec roots(Path.t()) :: %{
          longx: Path.t(),
          global: Path.t(),
          project: Path.t(),
          local: Path.t()
        }
  def roots(cwd) do
    %{
      longx: Path.join(:code.priv_dir(:longx), "agent/knowledge"),
      global: global_dir(),
      project: Longx.Agent.Definition.Layout.shared_dir(cwd, :knowledge),
      local: Longx.Agent.Definition.Layout.local_dir(cwd, :knowledge)
    }
  end

  # the directories each root is read from (the project's flat tree of before counts as shared)
  defp read_dirs(cwd) do
    roots(cwd)
    |> Map.new(fn {root, dir} -> {root, [dir]} end)
    |> Map.update!(:project, &(&1 ++ [Path.join(cwd, ".longx/knowledge")]))
  end

  @doc "Every doc of the given roots (all by default): shipped, global, project, local."
  @spec docs(Path.t(), [atom]) :: [doc]
  def docs(cwd, which \\ @roots) do
    dirs = read_dirs(cwd)

    for root <- @roots,
        root in which,
        dir <- dirs[root],
        File.dir?(dir),
        file <- dir |> Path.join("**/*.md") |> Path.wildcard() |> Enum.sort(),
        do: parse(root, Path.relative_to(file, dir), file)
  end

  @doc "The docs of one root grouped by topic: `{topic | nil, [doc]}` in path order."
  @spec by_topic([doc]) :: [{String.t() | nil, [doc]}]
  def by_topic(docs) do
    docs
    |> Enum.group_by(&topic_of/1)
    |> Enum.sort_by(fn {topic, _} -> topic || "" end)
  end

  @doc "The topic of a doc: the first directory under its root, nil for a flat doc."
  @spec topic_of(doc) :: String.t() | nil
  def topic_of(%{path: path}) do
    case String.split(path, "/") do
      [_root, topic, _ | _] -> topic
      _ -> nil
    end
  end

  @doc "The one line that speaks for a topic: its README's title and summary, else its first doc's."
  @spec topic_line([doc]) :: String.t()
  def topic_line(docs) do
    doc = Enum.find(docs, &String.ends_with?(&1.path, "/README.md")) || hd(docs)
    "#{doc.title}: #{doc.summary}"
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

  @doc "The body of one doc — or, for a topic (`project/deploy`), the list of its docs."
  @spec read(Path.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def read(cwd, path) do
    if Path.extname(path) == ".md" do
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
    else
      read_topic(cwd, String.trim_trailing(path, "/"))
    end
  end

  defp read_topic(cwd, path) do
    with [root, topic] when root in ~w(longx global project local) and topic != "" <-
           String.split(path, "/", parts: 2),
         docs when docs != [] <-
           cwd |> docs([String.to_existing_atom(root)]) |> Enum.filter(&(topic_of(&1) == topic)) do
      readme = Enum.find(docs, &String.ends_with?(&1.path, "/README.md"))
      lines = Enum.map_join(docs, "\n", &"- #{&1.path} — #{&1.title}: #{&1.summary}")
      head = if readme && readme.body != "", do: readme.body <> "\n\n", else: ""
      {:ok, head <> "Docs in #{path}/ (read one with knowledge_read):\n" <> lines}
    else
      [] -> {:error, "no knowledge topic #{path}"}
      _ -> {:error, "#{path}: a knowledge path is <root>/<topic>/<file>.md or <root>/<topic>"}
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
  naming `title` and `summary`; the path needs a topic
  (`<root>/<topic>/<name>.md`); `longx/…` is read-only; the global root
  commits every write; a local write keeps `.longx/local/` gitignored.
  """
  @spec write(Path.t(), String.t(), String.t()) :: {:ok, Path.t()} | {:error, String.t()}
  def write(cwd, path, content) do
    with {:ok, root, file} <- locate(cwd, path, :write),
         :ok <- writable(root),
         :ok <- in_topic(path),
         :ok <- well_formed(content),
         :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.write(file, content),
         :ok <- ignored(root, cwd),
         :ok <- commit(root, roots(cwd)[root], path) do
      {:ok, file}
    else
      {:error, reason} when is_atom(reason) ->
        {:error, "cannot write #{path}: #{:file.format_error(reason)}"}

      {:error, message} ->
        {:error, message}
    end
  end

  @doc "The whole file of one doc, front matter included (the editor's text)."
  @spec read_raw(Path.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def read_raw(cwd, path) do
    with {:ok, _root, file} <- locate(cwd, path) do
      case File.read(file) do
        {:ok, text} -> {:ok, text}
        {:error, :enoent} -> {:error, "no knowledge at #{path}"}
        {:error, reason} -> {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
      end
    end
  end

  @doc "Moves a local doc into the project's shared tree (`{:ok, \"project/…\"}`)."
  @spec promote(Path.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def promote(cwd, "local/" <> rel) do
    with {:ok, _to} <- Longx.Agent.Definition.Layout.promote(cwd, Path.join("knowledge", rel)) do
      {:ok, "project/" <> rel}
    end
  end

  def promote(_cwd, path), do: {:error, "only a local/… doc can be promoted, not #{path}"}

  @doc "Removes a doc (the global root commits the removal)."
  @spec delete(Path.t(), String.t()) :: :ok | {:error, String.t()}
  def delete(cwd, path) do
    with {:ok, root, file} <- locate(cwd, path),
         :ok <- writable(root),
         :ok <- rm(file, path),
         :ok <- commit(root, roots(cwd)[root], "remove " <> path) do
      :ok
    end
  end

  defp rm(file, path) do
    case File.rm(file) do
      :ok -> :ok
      {:error, :enoent} -> {:error, "no knowledge at #{path}"}
      {:error, reason} -> {:error, "cannot delete #{path}: #{:file.format_error(reason)}"}
    end
  end

  @doc """
  The person's global knowledge directory — the only thing at the global
  level (`config :longx, Longx.Agent.Knowledge, global_dir:`; dev
  `data/agent/knowledge`, prod `$LONGX_DATA_DIR/agent/knowledge`). A git
  repository when the machine has git, a plain directory otherwise.
  """
  @spec global_dir() :: Path.t()
  def global_dir do
    :longx
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get_lazy(:global_dir, fn -> Path.expand("data/agent/knowledge") end)
  end

  @doc "The docs of the shipped and the person's roots — what the settings page manages."
  @spec global_docs() :: [doc]
  def global_docs, do: docs(global_cwd(), [:longx, :global])

  # a working directory with no project root under it: the global roots alone
  @doc false
  def global_cwd, do: global_dir()

  # a read finds the file in any of the root's directories; a write goes to the root's own
  defp locate(cwd, path, mode \\ :read) do
    case String.split(path, "/", parts: 2) do
      [root, rel] when root in ["longx", "global", "project", "local"] and rel != "" ->
        root = String.to_existing_atom(root)
        dirs = if mode == :write, do: [roots(cwd)[root]], else: read_dirs(cwd)[root]

        candidates =
          for dir <- dirs,
              file = Path.expand(rel, dir),
              String.starts_with?(file, dir <> "/") and Path.extname(file) == ".md",
              do: file

        case candidates do
          [] -> {:error, "#{path} must be a .md file inside its root"}
          files -> {:ok, root, Enum.find(files, hd(files), &File.regular?/1)}
        end

      _ ->
        {:error,
         "#{path}: a knowledge path is <root>/<topic>/<file>.md with root longx, global, project or local"}
    end
  end

  defp writable(:longx), do: {:error, "the longx root is read-only (it ships with Longx)"}
  defp writable(_root), do: :ok

  # two levels: every doc belongs to a topic
  defp in_topic(path) do
    case String.split(path, "/") do
      [_root, topic, _file | _] when topic != "" ->
        :ok

      _ ->
        {:error,
         "#{path}: a doc needs a topic — write it as <root>/<topic>/<name>.md (a README.md in the topic may summarise it)"}
    end
  end

  defp ignored(:local, cwd) do
    case Longx.Agent.Definition.Layout.ensure_ignored(cwd) do
      :ok -> :ok
      {:error, reason} -> {:error, "cannot update .gitignore: #{:file.format_error(reason)}"}
    end
  end

  defp ignored(_root, _cwd), do: :ok

  defp well_formed(content) do
    case split_front_matter(content) do
      {%{"title" => t, "summary" => s}, _}
      when is_binary(t) and is_binary(s) and t != "" and s != "" ->
        :ok

      _ ->
        {:error, "the content must start with front matter (--- title: … summary: … ---)"}
    end
  end

  # the global root is a repository when the machine has git — a commit per
  # write, one at a time; without git it is a plain directory, and that is fine
  defp commit(:global, dir, path) do
    if Git.available?(), do: commit_global(dir, path), else: :ok
  end

  defp commit(_root, _dir, _path), do: :ok

  defp commit_global(dir, path) do
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
end
