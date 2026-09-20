defmodule Longx.Projects.Project.Changes.DeleteAttachments do
  @moduledoc "Deleting a project removes the files its messages attached (never the working directory)."
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _ctx) do
    # file removals outside the transaction: nothing of the disk is rolled
    # back, and the write lock is not held while the disk works
    Ash.Changeset.before_transaction(changeset, fn changeset ->
      Longx.Projects.Attachments.delete_all(changeset.data.id)
      changeset
    end)
  end
end
