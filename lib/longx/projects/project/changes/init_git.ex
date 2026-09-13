defmodule Longx.Projects.Project.Changes.InitGit do
  @moduledoc "With `init_git: true`, a directory that is not a repository yet becomes one right after the project is created."
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _ctx) do
    if Ash.Changeset.get_argument(changeset, :init_git) do
      Ash.Changeset.after_action(changeset, fn _changeset, project ->
        case Longx.Projects.init_git(project) do
          {:ok, _sha} -> {:ok, project}
          {:error, :already_a_repository} -> {:ok, project}
          {:error, reason} -> {:error, "git init failed: #{inspect(reason)}"}
        end
      end)
    else
      changeset
    end
  end
end
