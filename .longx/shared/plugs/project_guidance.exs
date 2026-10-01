defmodule Longx.ProjectGuidance do
  @moduledoc """
  Reads project guidance and agent skills in bounded sections, keeping large
  instruction documents out of every prompt.
  """

  use Longx.Agent.Plug

  instructions """
  For non-trivial repository changes, read the relevant sections of `AGENTS.md`
  with `project_guidance` before acting. For Ash/domain/resource changes, also
  read `.agents/skills/ash-framework/SKILL.md`; for Phoenix/web-layer changes,
  read `.agents/skills/phoenix-framework/SKILL.md` and any relevant references
  it names. Do not load every reference indiscriminately. Follow mandatory
  project checks in `AGENTS.md`, including `mix precommit` before declaring
  implementation work complete.
  """

  tool :project_guidance,
       "Reads a bounded section of AGENTS.md or a Markdown skill under .agents/skills.",
       show: :tool do
    param :path, :string, "AGENTS.md or a Markdown file under .agents/skills/", required: true
    param :start_line, :integer, "First line to read (1-based; defaults to 1)."
    param :max_lines, :integer, "Maximum lines to return (1–300; defaults to 200)."
  end

  @max_output_bytes 30_000

  def project_guidance(%{"path" => path} = args, ctx) do
    with {:ok, relative} <- allowed_path(path),
         {:ok, text} <- File.read(Path.join(ctx.cwd || File.cwd!(), relative)) do
      lines = String.split(text, "\n")
      start = max(integer(args["start_line"], 1), 1)
      count = min(max(integer(args["max_lines"], 200), 1), 300)
      selected = lines |> Enum.drop(start - 1) |> Enum.take(count) |> Enum.join("\n")
      selected = String.slice(selected, 0, @max_output_bytes)
      first = min(start, length(lines) + 1)
      last = min(start + count - 1, length(lines))

      {:ok, "#{relative} (lines #{first}-#{last}):\n\n#{selected}"}
    else
      {:error, :invalid_path} ->
        {:error, "path must be AGENTS.md or a Markdown file under .agents/skills/"}

      {:error, :enoent} ->
        {:error, "guidance file not found: #{path}"}

      {:error, reason} ->
        {:error, "could not read guidance: #{inspect(reason)}"}
    end
  end

  defp allowed_path("AGENTS.md"), do: {:ok, "AGENTS.md"}

  defp allowed_path(path) when is_binary(path) do
    allowed? =
      Path.type(path) != :absolute and
        ".." not in Path.split(path) and String.ends_with?(path, ".md") and
        String.starts_with?(path, ".agents/skills/")

    if allowed?, do: {:ok, path}, else: {:error, :invalid_path}
  end

  defp allowed_path(_), do: {:error, :invalid_path}

  defp integer(value, _default) when is_integer(value), do: value
  defp integer(_, default), do: default
end
