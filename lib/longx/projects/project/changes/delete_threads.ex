defmodule Longx.Projects.Project.Changes.DeleteThreads do
  @moduledoc """
  Deleting a project takes its thread and turn rows with it. They reference
  the project (foreign keys, no cascade in the schema), so without this the
  delete of any project that had a conversation failed with SQLite's
  "referenced something that does not exist". Each thread's agent is stopped
  and its transcript deleted with it.
  """
  use Ash.Resource.Change
  require Ash.Query

  @impl true
  def change(changeset, _opts, _ctx) do
    project_id = changeset.data.id

    changeset
    # the processes first, outside the transaction: `Longx.Agent.stop/1` waits
    # on the agent's callback in flight (up to 5 s + 15 s each, children
    # included), and an agent waiting for the write lock this transaction
    # would hold could never answer — every other writer then saw "database
    # is locked" for the whole wait
    |> Ash.Changeset.before_transaction(fn changeset ->
      for %{kernel_thread_id: id} <- threads(project_id) do
        Longx.Agent.Kernel.Specs.delete(id)
        Longx.Agent.stop(id)
      end

      changeset
    end)
    |> Ash.Changeset.before_action(fn changeset ->
      threads = threads(project_id)
      thread_ids = Enum.map(threads, & &1.id)

      for %{kernel_thread_id: id} <- threads, do: Longx.Agent.Transcript.delete!(id)

      Longx.Projects.Turn
      |> Ash.Query.filter(thread_id in ^thread_ids)
      |> Ash.bulk_destroy!(:destroy, %{}, authorize?: false)

      # the sub-agents' rows first: they point at their parents'
      Longx.Projects.Thread
      |> Ash.Query.filter(project_id == ^project_id and not is_nil(parent_thread_id))
      |> Ash.bulk_destroy!(:destroy, %{}, authorize?: false)

      Longx.Projects.Thread
      |> Ash.Query.filter(project_id == ^project_id)
      |> Ash.bulk_destroy!(:destroy, %{}, authorize?: false)

      # the watches' state rows (their files stay with the working directory)
      Longx.Watches.Watch
      |> Ash.Query.filter(project_id == ^project_id)
      |> Ash.bulk_destroy!(:destroy, %{}, authorize?: false)

      changeset
    end)
  end

  defp threads(project_id) do
    Longx.Projects.Thread
    |> Ash.Query.filter(project_id == ^project_id)
    |> Ash.read!(authorize?: false)
  end
end
