defmodule Longx.Tools.Memory.Read do
  @moduledoc "`memory.read`: MEMORY.md or one note, whole."
  @behaviour Longx.Codex.Tool

  @impl true
  def name, do: "read"

  @impl true
  def namespace, do: "memory"

  @impl true
  def enabled_by_default?, do: true

  @impl true
  def description,
    do:
      "Reads a file of Longx's global memory: MEMORY.md (the default) or a note named like notes/<file>.md, as memory.search reports them."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "file" => %{
          "type" => "string",
          "description" => "MEMORY.md (default) or notes/<name>.md."
        }
      },
      "additionalProperties" => false
    }
  end

  @impl true
  def call(args, _ctx) do
    file = Map.get(args, "file", "MEMORY.md")

    cond do
      file == "MEMORY.md" ->
        {:ok, Longx.Memory.index()}

      String.starts_with?(file, "notes/") and
          Path.basename(file) == String.trim_leading(file, "notes/") ->
        case File.read(Path.join(Longx.Memory.dir(), file)) do
          {:ok, text} -> {:ok, text}
          {:error, _} -> {:error, "no such note: #{file}"}
        end

      true ->
        {:error, "file must be MEMORY.md or notes/<name>.md"}
    end
  end
end
