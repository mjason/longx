defmodule Longx.Projects.Project.Changes.InitGit do
  @moduledoc """
  With `init_git: true`, a directory that is not a repository yet becomes
  one right after the project is created. A machine without git creates
  the project all the same: the page says git is missing.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _ctx) do
    if Ash.Changeset.get_argument(changeset, :init_git) do
      # after the transaction, not inside it: git runs through the shim for
      # a while, and the row's write lock is nobody else's to wait on
      Ash.Changeset.after_transaction(changeset, fn
        _changeset, {:ok, project} ->
          case Longx.Projects.init_git(project) do
            {:ok, _sha} -> {:ok, project}
            {:error, :already_a_repository} -> {:ok, project}
            {:error, :no_git} -> {:ok, project}
            {:error, reason} -> {:error, "git init failed: #{inspect(reason)}"}
          end

        _changeset, other ->
          other
      end)
    else
      changeset
    end
  end
end
