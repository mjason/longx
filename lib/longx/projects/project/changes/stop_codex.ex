defmodule Longx.Projects.Project.Changes.StopCodex do
  @moduledoc "Archiving or deleting a project stops its codex first (forced: the project is going away)."
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _ctx) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      :ok = Longx.Codex.Pool.stop(changeset.data.id)
      changeset
    end)
  end
end
