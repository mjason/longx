defmodule Longx.Agent.Plugs.Knowledge do
  @moduledoc """
  What the agent knows and learns, as files (`Longx.Agent.Knowledge`):
  the docs marked `always` go into every prompt (capped, `always_cap:`
  bytes), the rest as an index of one line each (capped, `index_cap:`
  docs), and three tools read, search and write them. This is the memory:
  not remembered, written down — the project's shared tree under
  `.longx/shared/knowledge/` with the code, its local tree
  (`.longx/local/knowledge/`, gitignored — where the agent writes by
  default), the person's in the global root, Longx's own shipped
  read-only. Docs live in topics; the index shows one line per topic.
  `roots:` picks which of `[:longx, :global, :project, :local]`.
  """

  use Longx.Agent.Plug

  alias Longx.Agent.Knowledge

  @defaults [roots: [:longx, :global, :project, :local], always_cap: 16 * 1024, index_cap: 200]

  tool :knowledge_read,
       "Reads one knowledge doc by its path (e.g. local/deploy/steps.md), or lists a topic (e.g. local/deploy)." do
    param :path,
          :string,
          "<root>/<topic>/<file>.md or <root>/<topic> — root is longx, global, project or local",
          required: true
  end

  tool :knowledge_search,
       "Finds knowledge lines containing every word of the query (titles and summaries included)." do
    param :query, :string, "Words to look for", required: true
  end

  tool :knowledge_write,
       "Creates or replaces a knowledge doc. Content starts with front matter: --- title: … summary: … tags: [a, b] always: false --- then markdown. Every doc lives in a topic: local/<topic>/<name>.md by default (this machine, not in git); project/<topic>/<name>.md only for what the person asked to share with the team (in git); global/<topic>/<name>.md for things about the person or their machine; longx/… is read-only." do
    param :path,
          :string,
          "local/<topic>/<name>.md (default), project/<topic>/<name>.md, or global/<topic>/<name>.md",
          required: true

    param :content, :string, "The whole doc, front matter first", required: true
  end

  # codex's memory decision boundary (ext/memories/templates/memories/read_path.md)
  # and its skills trigger rules (the gpt-5.6 instructions template, "Using
  # skills"), on one store: our knowledge is both what prior runs learned and
  # what the person wrote for the agent. The writing rules are ours — codex's
  # memory is consolidated offline, ours is written by the agent as it works.
  @growth """
  # Knowledge

  You have access to knowledge docs — guidance from prior runs, from the person and from Longx itself. They can save time and help you stay consistent. Use them whenever they are likely to help.

  Decision boundary: should you use the knowledge for a new user query?

  - Skip the knowledge ONLY when the request is clearly self-contained and does not need workspace history, conventions, or prior decisions.
  - Hard skip examples: current time/date, simple translation, simple sentence rewrite, one-line shell command, trivial formatting.
  - Use the knowledge by default when ANY of these are true: the query mentions a module, path or file named in the index below; the user asks for prior context, consistency or previous decisions; the task is ambiguous and could depend on earlier project choices; the ask is non-trivial and related to an indexed doc.
  - If unsure, do a quick pass with `knowledge_search`.

  Trigger rules: if the user names a doc OR the task clearly matches a doc's summary, read it completely with `knowledge_read` before taking task actions (a topic path lists its docs; read each required doc yourself, do not delegate reading or summarizing it). Multiple matches mean read them all. Do not carry docs across turns unless re-mentioned. Announce which docs you are using and why.

  Knowledge is not proof of current behavior. For consequential or changeable claims, use judgment about drift, verification cost, and harm; inspect the actual owning source when warranted and acknowledge material uncertainty. The shipped `longx/` docs and the plugs' own guidance take precedence over a local, project or global doc that contradicts them (a doc written before a Longx release changed the way): fix that doc, do not follow it.

  What is worth keeping is written down, never just remembered. When you learn something durable — a fact about the code, a decision and its reason, a procedure that worked, a pitfall — write it with `knowledge_write` as `local/<topic>/<name>.md` (yours, on this machine, not in git); `project/<topic>/<name>.md` is the shared tree the team reads, only for what the person asked to share; `global/<topic>/<name>.md` for things about the person or their machine. Pick an existing topic before opening a new one, and prefer improving a doc over adding one. Mark `always: true` only for what every turn must know; keep those short. Fix a doc that turned out wrong.
  """

  @impl true
  def init(opts), do: Keyword.merge(@defaults, opts)

  @impl true
  def call(%Step{phase: :request, cwd: cwd} = step, opts) do
    docs = Knowledge.docs(cwd || File.cwd!(), opts[:roots])
    {always, indexed} = Enum.split_with(docs, & &1.always?)

    step
    |> Step.instructions(always_section(always, opts[:always_cap]))
    |> Step.instructions(index_section(indexed, opts[:index_cap]))
    |> Step.instructions(@growth)
    |> Longx.Agent.Plug.mount(__MODULE__)
  end

  def call(step, _opts), do: step

  defp always_section([], _cap), do: nil

  defp always_section(docs, cap) do
    {kept, omitted} =
      Enum.reduce(docs, {[], []}, fn doc, {kept, omitted} ->
        text = "## #{doc.title} (#{doc.path})\n\n#{doc.body}"
        used = kept |> Enum.map(&byte_size/1) |> Enum.sum()

        if used + byte_size(text) <= cap,
          do: {kept ++ [text], omitted},
          else: {kept, omitted ++ [doc.path]}
      end)

    note =
      case omitted do
        [] ->
          ""

        paths ->
          "\n\n(#{length(paths)} always-docs omitted for size — read them with knowledge_read: #{Enum.join(paths, ", ")})"
      end

    "# Knowledge (always)\n\n" <> Enum.join(kept, "\n\n") <> note
  end

  defp index_section([], _cap), do: nil

  # one line per topic (a flat doc is its own line), capped
  defp index_section(docs, cap) do
    entries =
      docs
      |> Enum.group_by(& &1.root)
      |> Enum.sort_by(fn {root, _} ->
        Enum.find_index([:longx, :global, :project, :local], &(&1 == root))
      end)
      |> Enum.flat_map(fn {root, docs} ->
        docs
        |> Knowledge.by_topic()
        |> Enum.flat_map(fn
          {nil, flat} ->
            Enum.map(flat, &"- #{&1.path} — #{&1.title}: #{&1.summary}")

          {topic, in_topic} ->
            ["- #{root}/#{topic}/ (#{count(in_topic)}) — #{Knowledge.topic_line(in_topic)}"]
        end)
      end)

    {shown, rest} = Enum.split(entries, cap)

    note =
      case rest do
        [] -> ""
        more -> "\n\n(#{length(more)} more entries omitted — find them with knowledge_search)"
      end

    "# Knowledge index\n\nRead a doc with knowledge_read(path); a topic path (root/topic) lists its docs.\n\n" <>
      Enum.join(shown, "\n") <> note
  end

  # the README speaks for the topic, it is not one of its docs
  defp count(docs) do
    case Enum.count(docs, &(not String.ends_with?(&1.path, "/README.md"))) do
      1 -> "1 doc"
      n -> "#{n} docs"
    end
  end

  def knowledge_read(%{"path" => path}, ctx), do: Knowledge.read(ctx.cwd || File.cwd!(), path)

  def knowledge_search(%{"query" => query}, ctx) do
    case Knowledge.search(ctx.cwd || File.cwd!(), query) do
      [] -> {:ok, "nothing in the knowledge matches #{inspect(query)}"}
      hits -> {:ok, Enum.map_join(hits, "\n", &"#{&1.path}:#{&1.line}: #{&1.text}")}
    end
  end

  def knowledge_write(%{"path" => path, "content" => content}, ctx) do
    with {:ok, file} <- Knowledge.write(ctx.cwd || File.cwd!(), path, content) do
      {:ok, "wrote #{file}"}
    end
  end
end
