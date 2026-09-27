defmodule Longx.Projects.Project do
  @moduledoc """
  A project is a working directory the agent operates in, plus the defaults
  every thread started in it inherits: the model (nil → global default),
  web search, what to do when a turn starts on a dirty git tree, and the
  kernel's settings it overrides.

  `root_path` is absolute, must exist, and is unique: one project per
  directory. Whether it is a git repository is read live (`Longx.Projects.git_info/1`),
  never stored.
  """

  use Ash.Resource,
    otp_app: :longx,
    domain: Longx.Projects,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshGraphql.Resource]

  alias Longx.Projects.Types

  alias Longx.Projects.Project.{Changes, Validations}

  sqlite do
    table "projects"
    repo Longx.Repo
  end

  graphql do
    type :project
  end

  actions do
    defaults [:read, :destroy]

    # what the UI calls: deliberate, and the threads' history goes with the project
    destroy :delete do
      require_atomic? false
      argument :confirm, :boolean, default: false

      validate argument_equals(:confirm, true),
        message: "confirm: true is required to delete a project"

      change Changes.DeleteThreads
      change Changes.DeleteAttachments
    end

    create :create do
      primary? true

      # the wizard's "initialise git" checkbox
      argument :init_git, :boolean, default: false

      # the slug is derived from the name (rename via update)
      accept [
        :name,
        :description,
        :root_path,
        :web_search,
        :model_id,
        :trust_local_agent,
        :agent_settings
      ]

      change Changes.NormalizeRootPath
      change Changes.DeriveSlug
      change Changes.InitGit
      validate Validations.RootPathIsDirectory
      validate Validations.AgentSettings
    end

    update :update do
      primary? true
      require_atomic? false

      accept [
        :name,
        :slug,
        :description,
        :web_search,
        :model_id,
        :trust_local_agent,
        :agent_settings,
        :file_rules
      ]

      validate Validations.AgentSettings

      # the watcher of an open page reads the new rules
      change fn changeset, _ ->
        if Ash.Changeset.changing_attribute?(changeset, :file_rules) do
          Ash.Changeset.after_transaction(changeset, fn
            _cs, {:ok, project} ->
              Longx.Projects.Watcher.reload(project.id)
              {:ok, project}

            _cs, other ->
              other
          end)
        else
          changeset
        end
      end
    end

    update :archive do
      require_atomic? false
      change set_attribute(:archived_at, &DateTime.utc_now/0)
    end

    ## Generic actions the SPA calls (typed results in Longx.Projects.Types, GraphQL object types)

    action :git_info, Types.GitInfo do
      argument :id, :uuid, allow_nil?: false
      run fn input, _ -> with {:ok, project} <- fetch(input), do: {:ok, git_info_map(project)} end
    end

    # the composer's @ mentions: fuzzy file matches under the root
    action :search_files, {:array, Types.SearchFiles} do
      argument :id, :uuid, allow_nil?: false
      argument :query, :string, allow_nil?: false, constraints: [allow_empty?: true]

      run fn input, _ ->
        with {:ok, project} <- fetch(input),
             do: Longx.Projects.search_files(project, input.arguments.query)
      end
    end

    # the kernel's layered agent definition for this project, for the
    # settings page: the resolved plugs, the layers with their files, errors
    action :agent_definition, Types.AgentDefinition do
      argument :id, :uuid, allow_nil?: false

      run fn input, _ ->
        with {:ok, project} <- fetch(input), do: {:ok, Longx.Projects.agent_definition(project)}
      end
    end

    # a file of .longx/local/ moved into .longx/shared/ (reviewed, for the team)
    action :promote_local, Types.PromoteLocal do
      argument :id, :uuid, allow_nil?: false
      argument :path, :string, allow_nil?: false

      run fn input, _ ->
        with {:ok, project} <- fetch(input),
             {:ok, path} <- promote(project, input.arguments.path) do
          {:ok, %{path: path}}
        end
      end
    end

    action :init_git, Types.GitInfo do
      argument :id, :uuid, allow_nil?: false

      run fn input, _ ->
        with {:ok, project} <- fetch(input),
             {:ok, _info} <- init_git(project),
             do: {:ok, git_info_map(project)}
      end
    end

    read :by_slug do
      argument :slug, :string, allow_nil?: false
      get? true
      filter expr(slug == ^arg(:slug))
    end

    read :active do
      filter expr(is_nil(archived_at))
      prepare build(sort: [updated_at: :desc])
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string, allow_nil?: false, public?: true
    attribute :slug, :string, allow_nil?: false, public?: true
    attribute :description, :string, public?: true

    attribute :root_path, :string, allow_nil?: false, public?: true

    # whether threads get web search (`Plugs.WebSearch`); decided at thread start
    attribute :web_search, :boolean, allow_nil?: false, default: true, public?: true

    # whether the kernel may load the project's own agent definition
    # (`.longx/agent.exs`, `.longx/plugs/*.exs` — code that runs in Longx as
    # the person; off until the person looked at it)
    attribute :trust_local_agent, :boolean, allow_nil?: false, default: false, public?: true

    # the kernel's settings this project overrides (nil = the global
    # value): Longx.Agent.Definition.Settings' fields, validated by Validations.AgentSettings;
    # untyped on the wire so the client selects it by name (a typed map inside
    # the resource's field list is not what the page needs)
    attribute :agent_settings, :map, public?: true

    # what the file watcher and the tree ignore beyond the built-in lists and the
    # global setting: %{"ignore" => text, "watch" => text}, gitignore syntax
    # (`Longx.Projects.FileRules`)
    attribute :file_rules, :map, public?: true, allow_nil?: false, default: %{}

    attribute :archived_at, :utc_datetime_usec, public?: true

    timestamps public?: true
  end

  relationships do
    belongs_to :model, Longx.AI.Model, public?: true
    has_many :threads, Longx.Projects.Thread
  end

  # generic actions above resolve the project themselves (no record context)
  defp fetch(input), do: Ash.get(__MODULE__, input.arguments.id)

  defp promote(project, path) do
    case Longx.Projects.promote_local(project, path) do
      {:ok, shared} ->
        {:ok, shared}

      {:error, message} ->
        {:error,
         Ash.Error.Invalid.exception(
           errors: [%Ash.Error.Changes.InvalidArgument{field: :path, message: message}]
         )}
    end
  end

  # no git on the machine is an error the page can show, not a crash
  defp init_git(project) do
    case Longx.Projects.init_git(project) do
      {:error, :no_git} ->
        {:error,
         Ash.Error.Invalid.exception(
           errors: [
             %Ash.Error.Changes.InvalidArgument{field: :id, message: "git is not installed"}
           ]
         )}

      other ->
        other
    end
  end

  defp git_info_map(project) do
    %{repository?: repo, head: head, clean?: clean, changes: changes, lfs?: lfs} =
      Longx.Projects.git_info(project)

    %{repository: repo, head: head, clean: clean, changes: changes, lfs: lfs}
  end

  identities do
    identity :unique_slug, [:slug]
    identity :unique_root_path, [:root_path]
  end
end
