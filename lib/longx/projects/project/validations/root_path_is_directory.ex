defmodule Longx.Projects.Project.Validations.RootPathIsDirectory do
  @moduledoc false
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _ctx) do
    case Ash.Changeset.get_attribute(changeset, :root_path) do
      path when is_binary(path) ->
        if File.dir?(path),
          do: :ok,
          else: {:error, field: :root_path, message: "must be an existing directory"}

      _ ->
        :ok
    end
  end
end
