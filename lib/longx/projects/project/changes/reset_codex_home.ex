defmodule Longx.Projects.Project.Changes.ResetCodexHome do
  @moduledoc "Deleting a project removes its CODEX_HOME. The working directory is never touched."
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _ctx) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      File.rm_rf!(Longx.Codex.Pool.home_dir(changeset.data.id))
      changeset
    end)
  end
end
