defmodule Longx.Agent.Plugs.Knowledge do
  @moduledoc """
  What the agent knows and learns, as files (`Longx.Agent.Knowledge`):
  the docs marked `always` go into every prompt (capped, `always_cap:`
  bytes), the rest as an index of one line each (capped, `index_cap:`
  docs), and three tools read, search and write them. This is the memory:
  not remembered, written down — the project's under `.longx/knowledge/`
  with the code, the person's in the global root, Longx's own shipped
  read-only. `roots:` picks which of `[:longx, :global, :project]`.
  """

  use Longx.Agent.Plug

  alias Longx.Agent.Knowledge

  @defaults [roots: [:longx, :global, :project], always_cap: 16 * 1024, index_cap: 200]

  tool :knowledge_read,
       "Reads one knowledge doc by its path from the index (e.g. project/ops/deploy.md)." do
    param :path, :string, "<root>/<file>.md — root is longx, global or project", required: true
  end

  tool :knowledge_search,
       "Finds knowledge lines containing every word of the query (titles and summaries included)." do
    param :query, :string, "Words to look for", required: true
  end

  tool :knowledge_write,
       "Creates or replaces a knowledge doc. Content starts with front matter: --- title: … summary: … tags: [a, b] always: false --- then markdown. project/… for this project (committed with the code), global/… for things about the person or their machine; longx/… is read-only." do
    param :path, :string, "project/<name>.md or global/<name>.md", required: true
    param :content, :string, "The whole doc, front matter first", required: true
  end

  @growth """
  # Knowledge

  What is worth keeping is written down, never just remembered. Before guessing about this project, search the knowledge (knowledge_search) and read what applies (knowledge_read). When you learn something durable — a fact about the code, a decision and its reason, a procedure that worked, a pitfall — write it with knowledge_write: `project/<name>.md` for this project, `global/<name>.md` for things about the person or their machine. Mark `always: true` only for what every turn must know; keep those short. Fix a doc that turned out wrong.
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

  defp index_section(docs, cap) do
    {shown, rest} = Enum.split(docs, cap)
    lines = Enum.map_join(shown, "\n", &"- #{&1.path} — #{&1.title}: #{&1.summary}")

    note =
      case rest do
        [] -> ""
        more -> "\n\n(#{length(more)} more docs omitted — find them with knowledge_search)"
      end

    "# Knowledge index\n\nRead a doc with knowledge_read(path).\n\n" <> lines <> note
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
