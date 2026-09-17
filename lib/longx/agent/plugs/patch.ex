defmodule Longx.Agent.Plugs.Patch do
  @moduledoc """
  codex's `apply_patch` tool: the one edit format the models tuned for
  codex already know (`Longx.Agent.Patch`). A `function` tool taking the
  patch as `input` for every provider; for a provider that runs
  grammar-constrained custom tools (OpenAI) the same tool goes out as a
  `custom` tool with codex's lark grammar, so the model writes the patch
  raw — `Longx.Agent.Model` swaps the form per target. The instructions
  are codex's own (`priv/agent/apply_patch.md`).
  """

  use Longx.Agent.Plug

  alias Longx.Agent.Patch

  @instructions_path Path.join(:code.priv_dir(:longx), "agent/apply_patch.md")
  @grammar_path Path.join(:code.priv_dir(:longx), "agent/apply_patch.lark")
  @external_resource @instructions_path
  @external_resource @grammar_path

  instructions File.read!(@instructions_path)

  tool :apply_patch,
       "Edits files with a patch in the apply_patch format (see the instructions): add, delete, update (with optional move) — the whole patch text, `*** Begin Patch` to `*** End Patch`, as `input`.",
       show: :file_change,
       freeform: %{syntax: "lark", definition: File.read!(@grammar_path), param: "input"} do
    param :input, :string, "The complete patch text", required: true
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
