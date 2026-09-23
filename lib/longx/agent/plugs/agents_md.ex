defmodule Longx.Agent.Plugs.AgentsMd do
  @moduledoc """
  The project's own instructions, as codex reads them (`codex-rs/core/src/
  agents_md.rs`): the project root is the nearest directory from the cwd up
  that holds a `.git` (none: the cwd alone); every directory from that root
  down to the cwd gives its `AGENTS.override.md`, else its `AGENTS.md`, root
  first so the nearest has the last word — never a directory above the root.
  One budget for them all (codex's `project_doc_max_bytes`, 32 KiB,
  `max_bytes:`): the file that passes it is cut, the rest left out; a blank
  file counts for nothing. `root_markers:` is codex's `project_root_markers`
  (`[".git"]`; an empty list: the cwd alone).

  The block is codex's user instructions fragment (`context/
  user_instructions.rs`): `# AGENTS.md instructions for <cwd>` and the files'
  text inside `<INSTRUCTIONS>`, joined by a blank line. Codex sends it as a
  user message; here it is instructions, as Environment's
  `<environment_context>` is.

  In the shipped pipeline after Base (codex reads AGENTS.md by default); a
  description turns it off with `drop AgentsMd`. Longx's trust switch guards
  code a project brings (`.longx/agent.exs`, its plugs), not this text: an
  untrusted project's AGENTS.md is read too.
  """

  use Longx.Agent.Plug

  @file_names ["AGENTS.override.md", "AGENTS.md"]

  @impl true
  def init(opts),
    do: %{
      max: Keyword.get(opts, :max_bytes, 32 * 1024),
      markers: Keyword.get(opts, :root_markers, [".git"])
    }

  @impl true
  def call(%Step{phase: phase} = step, _opts) when phase != :request, do: step
  def call(%Step{cwd: nil} = step, _opts), do: step

  def call(%Step{cwd: cwd} = step, %{max: max, markers: markers}) do
    cwd = Path.expand(cwd)

    case cwd |> search_dirs(markers) |> Enum.flat_map(&doc_in/1) |> read_within(max) do
      [] ->
        step

      texts ->
        Step.instructions(
          step,
          "# AGENTS.md instructions for #{cwd}\n\n<INSTRUCTIONS>\n" <>
            Enum.join(texts, "\n\n") <> "\n</INSTRUCTIONS>"
        )
    end
  end

  # the project root (the nearest ancestor with a marker, the cwd included) down
  # to the cwd; without a root, the cwd alone
  defp search_dirs(cwd, markers) do
    chain = ancestors(cwd)

    case Enum.find_index(chain, &root?(&1, markers)) do
      nil -> [cwd]
      i -> chain |> Enum.take(i + 1) |> Enum.reverse()
    end
  end

  # the directory and its parents, the directory first
  defp ancestors(dir) do
    Stream.unfold(dir, fn
      nil -> nil
      d -> {d, if(Path.dirname(d) == d, do: nil, else: Path.dirname(d))}
    end)
    |> Enum.to_list()
  end

  defp root?(dir, markers), do: Enum.any?(markers, &File.exists?(Path.join(dir, &1)))

  # the directory's override, else its AGENTS.md
  defp doc_in(dir) do
    @file_names
    |> Enum.map(&Path.join(dir, &1))
    |> Enum.find(&File.regular?/1)
    |> List.wrap()
  end

  defp read_within(paths, max) do
    paths
    |> Enum.reduce_while({max, []}, fn
      _path, {0, acc} ->
        {:halt, {0, acc}}

      path, {left, acc} ->
        case File.read(path) do
          {:ok, text} ->
            text = if byte_size(text) > left, do: binary_part(text, 0, left), else: text
            text = Longx.Agent.Text.utf8(text)

            if String.trim(text) == "",
              do: {:cont, {left, acc}},
              else: {:cont, {max(left - byte_size(text), 0), [text | acc]}}

          {:error, _} ->
            {:cont, {left, acc}}
        end
    end)
    |> elem(1)
    |> Enum.reverse()
  end
end
