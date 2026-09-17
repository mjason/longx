defmodule Longx.Projects.Repo do
  @moduledoc """
  A resource without data: the git tool (GitHub Desktop's shape — changes,
  history, branches, the remote) as generic actions over `Longx.Git` for one
  project. Everything runs the system git in the project root; a project
  that is no repository answers `repository: false` to `git_changes` and an
  error on `project_id` to everything else.
  """

  use Ash.Resource,
    otp_app: :longx,
    domain: Longx.Projects,
    extensions: [AshTypescript.Resource]

  alias Longx.Git

  typescript do
    type_name "ProjectRepo"
  end

  @diff [binary: [type: :boolean, allow_nil?: false], diff: [type: :string, allow_nil?: false]]
  @sha [sha: [type: :string, allow_nil?: false]]

  actions do
    # the Changes view + the sync state, in one call
    action :git_changes, :map do
      constraints fields: [
                    repository: [type: :boolean, allow_nil?: false],
                    branch: [type: :string],
                    head: [type: :string],
                    changes: [type: {:array, :map}, allow_nil?: false],
                    ahead: [type: :integer],
                    behind: [type: :integer],
                    remotes: [type: {:array, :map}, allow_nil?: false],
                    lfs: [type: :boolean, allow_nil?: false],
                    # what .gitignore hides (the tree dims them); a merge stopped on conflicts
                    ignored: [type: {:array, :string}, allow_nil?: false],
                    merging: [type: :boolean, allow_nil?: false]
                  ]

      argument :project_id, :uuid, allow_nil?: false

      run fn input, _ ->
        with {:ok, dir} <- dir(input) do
          if Git.repository?(dir) do
            %{clean?: _, changes: changes} = Git.status(dir)
            sync = Git.ahead_behind(dir)

            {:ok,
             %{
               repository: true,
               branch: Git.branches(dir).current,
               head: head_or_nil(dir),
               changes: changes,
               ahead: sync && sync.ahead,
               behind: sync && sync.behind,
               remotes: Git.remotes(dir),
               lfs: Git.lfs?(dir),
               ignored: Git.ignored(dir),
               merging: Git.merging?(dir)
             }}
          else
            {:ok,
             %{
               repository: false,
               branch: nil,
               head: nil,
               changes: [],
               ahead: nil,
               behind: nil,
               remotes: [],
               lfs: false,
               ignored: [],
               merging: false
             }}
          end
        end
      end
    end

    action :git_file_diff, :map do
      constraints fields: @diff
      argument :project_id, :uuid, allow_nil?: false
      argument :path, :string, allow_nil?: false

      run fn input, _ ->
        with {:ok, dir} <- repo(input), do: {:ok, Git.file_diff(dir, input.arguments.path)}
      end
    end

    action :git_commit, :map do
      constraints fields: @sha
      argument :project_id, :uuid, allow_nil?: false
      argument :paths, {:array, :string}, allow_nil?: false
      argument :message, :string, allow_nil?: false

      run fn input, _ ->
        with {:ok, dir} <- repo(input),
             {:ok, sha} <-
               Git.commit(dir, input.arguments.message, paths: input.arguments.paths)
               |> on(:paths) do
          {:ok, %{sha: sha}}
        end
      end
    end

    action :git_discard do
      argument :project_id, :uuid, allow_nil?: false
      argument :paths, {:array, :string}, allow_nil?: false

      run fn input, _ ->
        with {:ok, dir} <- repo(input), do: Git.discard(dir, input.arguments.paths) |> on(:paths)
      end
    end

    action :git_abort_merge do
      argument :project_id, :uuid, allow_nil?: false

      run fn input, _ ->
        with {:ok, dir} <- repo(input) do
          if Git.merging?(dir),
            do: Git.abort_merge(dir) |> on(:project_id),
            else: invalid(:project_id, "no merge is in progress")
        end
      end
    end

    action :git_undo_commit, :map do
      constraints fields: @sha
      argument :project_id, :uuid, allow_nil?: false

      run fn input, _ ->
        with {:ok, dir} <- repo(input),
             {:ok, sha} <- Git.undo_commit(dir) |> on(:project_id),
             do: {:ok, %{sha: sha}}
      end
    end

    # the History view
    action :git_log, {:array, :map} do
      constraints items: [
                    fields: [
                      sha: [type: :string, allow_nil?: false],
                      subject: [type: :string, allow_nil?: false],
                      author: [type: :string, allow_nil?: false],
                      email: [type: :string, allow_nil?: false],
                      # ISO 8601: a typed map's utc_datetime has no client-side type in ash_typescript 0.18
                      at: [type: :string, allow_nil?: false]
                    ]
                  ]

      argument :project_id, :uuid, allow_nil?: false
      argument :limit, :integer, default: 50
      argument :skip, :integer, default: 0

      run fn input, _ ->
        with {:ok, dir} <- repo(input),
             do:
               {:ok,
                dir
                |> Git.log(limit: input.arguments.limit, skip: input.arguments.skip)
                |> Enum.map(&iso_at/1)}
      end
    end

    action :git_show, :map do
      constraints fields: [
                    sha: [type: :string, allow_nil?: false],
                    subject: [type: :string, allow_nil?: false],
                    body: [type: :string, allow_nil?: false],
                    author: [type: :string, allow_nil?: false],
                    email: [type: :string, allow_nil?: false],
                    at: [type: :string, allow_nil?: false],
                    parents: [type: {:array, :string}, allow_nil?: false],
                    files: [type: {:array, :map}, allow_nil?: false]
                  ]

      argument :project_id, :uuid, allow_nil?: false
      argument :sha, :string, allow_nil?: false

      run fn input, _ ->
        with {:ok, dir} <- repo(input) do
          case Git.show(dir, input.arguments.sha) do
            {:error, _} = error -> on(error, :sha)
            commit -> {:ok, iso_at(commit)}
          end
        end
      end
    end

    action :git_commit_file_diff, :map do
      constraints fields: @diff
      argument :project_id, :uuid, allow_nil?: false
      argument :sha, :string, allow_nil?: false
      argument :path, :string, allow_nil?: false

      run fn input, _ ->
        with {:ok, dir} <- repo(input) do
          case Git.commit_file_diff(dir, input.arguments.sha, input.arguments.path) do
            {:error, _} = error -> on(error, :sha)
            diff -> {:ok, diff}
          end
        end
      end
    end

    # both whole texts, for the side-by-side view (sha nil: HEAD vs the working tree)
    action :git_file_versions, :map do
      constraints fields: [
                    before: [type: :string],
                    after: [type: :string],
                    binary: [type: :boolean, allow_nil?: false]
                  ]

      argument :project_id, :uuid, allow_nil?: false
      argument :sha, :string
      argument :path, :string, allow_nil?: false

      run fn input, _ ->
        with {:ok, dir} <- repo(input) do
          {:ok, Git.file_versions(dir, input.arguments[:sha], input.arguments.path)}
        end
      end
    end

    # Branches (and the stash, which is what a switch with changes needs)
    action :git_branches, :map do
      constraints fields: [
                    current: [type: :string],
                    branches: [type: {:array, :map}, allow_nil?: false],
                    stashes: [type: {:array, :map}, allow_nil?: false]
                  ]

      argument :project_id, :uuid, allow_nil?: false

      run fn input, _ ->
        with {:ok, dir} <- repo(input) do
          %{current: current, branches: branches} = Git.branches(dir)
          {:ok, %{current: current, branches: branches, stashes: Git.stashes(dir)}}
        end
      end
    end

    action :git_create_branch do
      argument :project_id, :uuid, allow_nil?: false
      argument :name, :string, allow_nil?: false

      run fn input, _ ->
        with {:ok, dir} <- repo(input),
             do: Git.create_branch(dir, input.arguments.name) |> on(:name)
      end
    end

    # `stash: true` sets the working tree aside first (GitHub Desktop's
    # "stash changes and switch"); without it, changes in the way refuse
    action :git_switch do
      argument :project_id, :uuid, allow_nil?: false
      argument :name, :string, allow_nil?: false
      argument :stash, :boolean, default: false

      run fn input, _ ->
        with {:ok, dir} <- repo(input),
             :ok <- if(input.arguments.stash, do: stash_if_dirty(dir), else: :ok) |> on(:name),
             do: Git.switch(dir, input.arguments.name) |> on(:name)
      end
    end

    action :git_delete_branch do
      argument :project_id, :uuid, allow_nil?: false
      argument :name, :string, allow_nil?: false
      argument :force, :boolean, default: false

      run fn input, _ ->
        with {:ok, dir} <- repo(input),
             do:
               Git.delete_branch(dir, input.arguments.name, force: input.arguments.force)
               |> on(:name)
      end
    end

    action :git_stash_pop do
      argument :project_id, :uuid, allow_nil?: false

      run fn input, _ ->
        with {:ok, dir} <- repo(input), do: Git.stash_pop(dir) |> on(:project_id)
      end
    end

    # The remote
    action :git_set_remote do
      argument :project_id, :uuid, allow_nil?: false
      argument :name, :string, allow_nil?: false
      argument :url, :string, allow_nil?: false

      run fn input, _ ->
        with {:ok, dir} <- repo(input),
             do: Git.set_remote(dir, input.arguments.name, input.arguments.url) |> on(:url)
      end
    end

    action :git_fetch do
      argument :project_id, :uuid, allow_nil?: false
      run fn input, _ -> with {:ok, dir} <- repo(input), do: Git.fetch(dir) |> on(:project_id) end
    end

    action :git_pull do
      argument :project_id, :uuid, allow_nil?: false
      run fn input, _ -> with {:ok, dir} <- repo(input), do: Git.pull(dir) |> on(:project_id) end
    end

    action :git_push do
      argument :project_id, :uuid, allow_nil?: false
      run fn input, _ -> with {:ok, dir} <- repo(input), do: Git.push(dir) |> on(:project_id) end
    end
  end

  defp dir(input) do
    with {:ok, project} <- Ash.get(Longx.Projects.Project, input.arguments.project_id),
         do: {:ok, project.root_path}
  end

  defp repo(input) do
    with {:ok, dir} <- dir(input) do
      if Git.repository?(dir),
        do: {:ok, dir},
        else: invalid(:project_id, "is not a git repository")
    end
  end

  defp iso_at(%{at: %DateTime{} = at} = entry), do: %{entry | at: DateTime.to_iso8601(at)}

  defp head_or_nil(dir) do
    case Git.head(dir) do
      {:ok, sha} -> sha
      _ -> nil
    end
  end

  defp stash_if_dirty(dir) do
    if Git.status(dir).clean?, do: :ok, else: Git.stash(dir, "longx: before switching branch")
  end

  # git's own words go to the person, on the argument they concern
  defp on(:ok, _field), do: :ok
  defp on({:ok, _} = ok, _field), do: ok
  defp on({:error, %Git.Error{} = error}, field), do: invalid(field, Git.Error.message(error))
  defp on({:error, :nothing_to_commit}, field), do: invalid(field, "carry no change to commit")
  defp on({:error, :root_commit}, field), do: invalid(field, "the first commit cannot be undone")
  defp on({:error, reason}, field), do: invalid(field, "failed: #{inspect(reason)}")

  defp invalid(field, message) do
    {:error,
     Ash.Error.to_error_class(
       Ash.Error.Changes.InvalidArgument.exception(field: field, message: message)
     )}
  end
end
