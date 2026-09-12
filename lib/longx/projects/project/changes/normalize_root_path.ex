defmodule Longx.Projects.Project.Changes.NormalizeRootPath do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _ctx) do
    case Ash.Changeset.get_attribute(changeset, :root_path) do
      path when is_binary(path) ->
        Ash.Changeset.force_change_attribute(changeset, :root_path, Path.expand(path))

      _ ->
        changeset
    end
  end
end
