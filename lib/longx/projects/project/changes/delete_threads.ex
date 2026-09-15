defmodule Longx.Projects.Project.Changes.DeleteThreads do
  @moduledoc """
  Deleting a project takes its thread and turn rows with it. They reference
  the project (foreign keys, no cascade in the schema), so without this the
  delete of any project that had a conversation failed with SQLite's
  "referenced something that does not exist". Codex's own copy of the
  conversations goes with the home (`ResetCodexHome`).
  """
  use Ash.Resource.Change
  require Ash.Query

  @impl true
  def change(changeset, _opts, _ctx) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      project_id = changeset.data.id

      thread_ids =
        Longx.Projects.Thread
        |> Ash.Query.filter(project_id == ^project_id)
        |> Ash.read!(authorize?: false)
        |> Enum.map(& &1.id)

      Longx.Projects.Turn
      |> Ash.Query.filter(thread_id in ^thread_ids)
      |> Ash.bulk_destroy!(:destroy, %{}, authorize?: false)

      Longx.Projects.Thread
      |> Ash.Query.filter(project_id == ^project_id)
      |> Ash.bulk_destroy!(:destroy, %{}, authorize?: false)

      changeset
    end)
  end
end
