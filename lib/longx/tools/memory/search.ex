defmodule Longx.Tools.Memory.Search do
  @moduledoc "`memory.search`: lines of the global memory matching every word of a query."
  @behaviour Longx.Codex.Tool

  @impl true
  def name, do: "search"

  @impl true
  def namespace, do: "memory"

  @impl true
  def enabled_by_default?, do: true

  @impl true
  def description,
    do:
      "Searches Longx's global memory (MEMORY.md and the notes) for lines containing every word of the query, case-insensitively. Use it before assuming a preference or a past decision."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "query" => %{"type" => "string", "description" => "Keywords to look for."}
      },
      "required" => ["query"],
      "additionalProperties" => false
    }
  end

  @impl true
  def call(%{"query" => query}, _ctx) do
    hits =
      for hit <- Longx.Memory.search(Longx.Memory.dir(), query),
          do: %{"file" => hit.file, "line" => hit.line, "text" => hit.text}

    # a tool answers with text: JSON the model reads back
    {:ok, Jason.encode!(%{"hits" => hits})}
  end
end
