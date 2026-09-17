defmodule Longx.Projects.Project.Validations.AgentSettings do
  @moduledoc "The project's kernel overrides follow `Longx.Agent.Settings`' rules (nil = inherit)."
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :agent_settings) do
      nil ->
        :ok

      attrs when is_map(attrs) ->
        case Longx.Agent.Settings.validate(attrs) do
          :ok ->
            :ok

          {:error, %{field: field, message: message}} ->
            {:error, field: :agent_settings, message: "#{field}: #{message}"}
        end
    end
  end
end
