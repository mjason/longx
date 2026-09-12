defmodule Longx.Projects.Project.Validations.ToolsAreRegistered do
  @moduledoc false
  use Ash.Resource.Validation

  alias Longx.Codex.Tool.Registry

  @impl true
  def validate(changeset, _opts, _ctx) do
    unknown =
      changeset
      |> Ash.Changeset.get_attribute(:tools)
      |> List.wrap()
      |> Enum.reject(&match?({:ok, _}, Registry.fetch_qualified(&1)))

    case unknown do
      [] -> :ok
      names -> {:error, field: :tools, message: "unknown tools: #{Enum.join(names, ", ")}"}
    end
  end
end
