defmodule Longx.Tools.Memory.Note do
  @moduledoc "`memory.note`: the agent puts one thing into the global memory's inbox."
  @behaviour Longx.Codex.Tool

  alias Longx.Codex.Tool.Context

  @impl true
  def name, do: "note"

  @impl true
  def namespace, do: "memory"

  @impl true
  def enabled_by_default?, do: true

  @impl true
  def description,
    do:
      "Adds one note to Longx's global memory (shared across all projects) when the user explicitly asks to remember, forget or change something for the future. One fact per note, stated plainly; never secrets."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "note" => %{
          "type" => "string",
          "description" => "The note, in the user's language. One fact or preference."
        },
        "slug" => %{
          "type" => "string",
          "description" => "Optional short name for the note file (letters, digits, hyphens)."
        }
      },
      "required" => ["note"],
      "additionalProperties" => false
    }
  end

  @impl true
  def call(%{"note" => note} = args, %Context{thread_id: thread_id}) do
    opts = [thread: thread_id, project: project_name(thread_id), slug: args["slug"]]

    case Longx.Memory.add_note(
           Longx.Memory.dir(),
           note,
           Enum.reject(opts, fn {_, v} -> is_nil(v) end)
         ) do
      {:ok, file} -> {:ok, file}
      {:error, :empty} -> {:error, "the note is empty"}
      {:error, reason} -> {:error, "could not write the note: #{inspect(reason)}"}
    end
  end

  # the project the thread belongs to, when Longx knows the thread
  defp project_name(nil), do: nil

  defp project_name(codex_thread_id) do
    case Longx.Projects.get_thread_by_codex_id(codex_thread_id, load: :project) do
      {:ok, %{project: %{name: name}}} -> name
      _ -> nil
    end
  end
end
