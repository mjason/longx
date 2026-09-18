defmodule Longx.Agent.Plugs.Patch do
  @moduledoc """
  codex's `apply_patch` tool: the one edit format the models tuned for
  codex already know (`Longx.Agent.Tools.Patch`). A `function` tool taking the
  patch as `input` for every provider; for a provider that runs
  grammar-constrained custom tools (OpenAI) the same tool goes out as a
  `custom` tool with codex's lark grammar, so the model writes the patch
  raw — `Longx.Agent.Model` swaps the form per target. The instructions
  are codex's own (`priv/agent/apply_patch.md`).
  """

  use Longx.Agent.Plug

  alias Longx.Agent.Tools.Patch

  @instructions_path Path.join(:code.priv_dir(:longx), "agent/apply_patch.md")
  @grammar_path Path.join(:code.priv_dir(:longx), "agent/apply_patch.lark")
  @external_resource @instructions_path
  @external_resource @grammar_path

  instructions File.read!(@instructions_path)

  tool :apply_patch,
       "Edits files with a patch in the apply_patch format (see the instructions): add, delete, update (with optional move) — the whole patch text, `*** Begin Patch` to `*** End Patch`, as `input`.",
       show: :file_change,
       freeform: %{syntax: "lark", definition: File.read!(@grammar_path), param: "input"},
       prepare: &__MODULE__.normalize/1 do
    param :input, :string, "The complete patch text", required: true
  end

  @doc """
  The patch as the model meant it: under `patch` / `text` / `content` /
  `diff` instead of `input`, newlines escaped once too often (a text with
  no real newline and literal `\\n`), or wrapped in a markdown fence —
  slips seen from third-party models that read as "missing *** End Patch".
  """
  @spec normalize(map) :: map
  def normalize(%{"input" => text} = args) when is_binary(text),
    do: Map.put(args, "input", text |> unfence() |> unescape_newlines())

  def normalize(args) when is_map(args) do
    case Enum.find(~w(patch text content diff), &is_binary(args[&1])) do
      nil -> args
      key -> args |> Map.delete(key) |> Map.put("input", args[key]) |> normalize()
    end
  end

  def normalize(other), do: other

  defp unfence(text) do
    case Regex.run(~r/\A\s*```[\w-]*\r?\n(.*?)\r?\n?```\s*\z/s, text, capture: :all_but_first) do
      [inner] -> inner <> "\n"
      _ -> text
    end
  end

  # only when there is no real newline at all: a patch with a `\n` inside a
  # line (a string literal in an added line) keeps it
  defp unescape_newlines(text) do
    if String.contains?(text, "\n") or not String.contains?(text, "\\n"),
      do: text,
      else: String.replace(text, "\\n", "\n")
  end

  def apply_patch(%{"input" => text}, ctx) do
    cwd = ctx.cwd || File.cwd!()

    with {:ok, hunks} <- Patch.parse(text),
         {:ok, changes} <- Patch.apply(hunks, cwd) do
      {:ok, "Done!\n" <> summary(changes), %{"changes" => changes}}
    end
  end

  defp summary(changes) do
    Enum.map_join(changes, "\n", fn
      %{"kind" => "add", "path" => path} -> "A #{path}"
      %{"kind" => "delete", "path" => path} -> "D #{path}"
      %{"kind" => "update", "path" => path, "moved_from" => from} -> "M #{from} -> #{path}"
      %{"kind" => "update", "path" => path} -> "M #{path}"
    end)
  end
end
