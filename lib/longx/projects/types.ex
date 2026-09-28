defmodule Longx.Projects.Types do
  @moduledoc """
  The typed results of the Longx.Projects actions the page reads, as Ash map
  types with a GraphQL name: only a `NewType` with `graphql_type/1` is an
  object type to AshGraphql (an inline `:map` with `fields` is a `Json`
  scalar); nested `fields` are typed with it, named `<type>_<field>`.
  """

  defmodule GitInfo do
    @moduledoc "`Longx.Projects.Project.git_info` and other actions returning `@git_info`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          repository: [type: :boolean, allow_nil?: false],
          head: [type: :string],
          clean: [type: :boolean],
          changes: [type: :integer, allow_nil?: false],
          lfs: [type: :boolean, allow_nil?: false]
        ]
      ]

    def graphql_type(_), do: :git_info
  end

  defmodule SearchFiles do
    @moduledoc "the result of `Longx.Projects.Project.search_files`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          path: [type: :string, allow_nil?: false],
          file_name: [type: :string, allow_nil?: false],
          root: [type: :string, allow_nil?: false],
          match_type: [type: :string, allow_nil?: false],
          score: [type: :integer, allow_nil?: false],
          indices: [type: {:array, :integer}]
        ]
      ]

    def graphql_type(_), do: :search_files
  end

  defmodule AgentDefinition do
    @moduledoc "the result of `Longx.Projects.Project.agent_definition`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          present: [type: :boolean, allow_nil?: false],
          trusted: [type: :boolean, allow_nil?: false],
          dir: [type: :string, allow_nil?: false],
          model: [type: :string],
          effort: [type: :string],
          plugs: [type: {:array, :string}, allow_nil?: false],
          files: [type: {:array, :string}, allow_nil?: false],
          local_files: [type: {:array, :string}, allow_nil?: false],
          # untyped: ash_typescript 0.18 cannot select inside an array of typed maps
          agents: [type: {:array, :map}, allow_nil?: false],
          settings: [
            type: :map,
            allow_nil?: false,
            constraints: [
              fields: [
                max_depth: [type: :integer],
                max_children: [type: :integer],
                idle_minutes: [type: :integer],
                model_retries: [type: :integer],
                command_oom_priority: [type: :integer],
                command_memory_percent: [type: :integer],
                memory_floor_percent: [type: :integer],
                child_model: [type: :string],
                child_effort: [type: :string]
              ]
            ]
          ],
          overrides: [
            type: :map,
            allow_nil?: false,
            constraints: [
              fields: [
                max_depth: [type: :integer],
                max_children: [type: :integer],
                idle_minutes: [type: :integer],
                model_retries: [type: :integer],
                command_oom_priority: [type: :integer],
                command_memory_percent: [type: :integer],
                memory_floor_percent: [type: :integer],
                child_model: [type: :string],
                child_effort: [type: :string]
              ]
            ]
          ],
          errors: [type: {:array, :string}, allow_nil?: false],
          # what `plug Browser` resolves to on this machine; nil without the plug
          browser: [
            type: :map,
            constraints: [
              fields: [
                alias: [type: :string],
                max_tabs: [type: :integer, allow_nil?: false],
                state: [type: :string, allow_nil?: false],
                browser: [type: :string]
              ]
            ]
          ]
        ]
      ]

    def graphql_type(_), do: :agent_definition
  end

  defmodule PromoteLocal do
    @moduledoc "the result of `Longx.Projects.Project.promote_local`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [fields: [path: [type: :string, allow_nil?: false]]]

    def graphql_type(_), do: :promote_local
  end

  defmodule SteerTurn do
    @moduledoc "the result of `Longx.Projects.Thread.steer_turn`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [fields: [kernel_turn_id: [type: :string, allow_nil?: false]]]

    def graphql_type(_), do: :steer_turn
  end

  defmodule RetractTurn do
    @moduledoc "the result of `Longx.Projects.Thread.retract_turn`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [fields: [text: [type: :string, allow_nil?: false]]]

    def graphql_type(_), do: :retract_turn
  end

  defmodule Goal do
    @moduledoc "`Longx.Projects.Thread.set_goal` and other actions returning `@goal_fields`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          objective: [type: :string, allow_nil?: false],
          status: [type: :string, allow_nil?: false],
          token_budget: [type: :integer],
          tokens_used: [type: :integer, allow_nil?: false],
          time_used_seconds: [type: :integer, allow_nil?: false]
        ]
      ]

    def graphql_type(_), do: :goal
  end

  defmodule ClearGoal do
    @moduledoc "the result of `Longx.Projects.Thread.clear_goal`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [fields: [cleared: [type: :boolean, allow_nil?: false]]]

    def graphql_type(_), do: :clear_goal
  end

  defmodule ListRunning do
    @moduledoc "the result of `Longx.Projects.Thread.list_running`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [fields: [threads: [type: {:array, :map}, allow_nil?: false]]]

    def graphql_type(_), do: :list_running
  end

  defmodule ListRecent do
    @moduledoc "the result of `Longx.Projects.Thread.list_recent`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [fields: [threads: [type: {:array, :map}, allow_nil?: false]]]

    def graphql_type(_), do: :list_recent
  end

  defmodule Directory do
    @moduledoc "the result of `Longx.Projects.Thread.directory`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [fields: [sessions: [type: {:array, :map}, allow_nil?: false]]]

    def graphql_type(_), do: :directory
  end

  defmodule FilesEntry do
    @moduledoc "`Longx.Projects.Files.list_files` and other actions returning `@entry`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          name: [type: :string, allow_nil?: false],
          path: [type: :string, allow_nil?: false],
          kind: [type: :atom, constraints: [one_of: [:file, :dir]], allow_nil?: false],
          size: [type: :integer, allow_nil?: false]
        ]
      ]

    def graphql_type(_), do: :files_entry
  end

  defmodule ReadFile do
    @moduledoc "the result of `Longx.Projects.Files.read_file`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          path: [type: :string, allow_nil?: false],
          content: [type: :string],
          size: [type: :integer, allow_nil?: false],
          binary: [type: :boolean, allow_nil?: false],
          truncated: [type: :boolean, allow_nil?: false]
        ]
      ]

    def graphql_type(_), do: :read_file
  end

  defmodule GitChanges do
    @moduledoc "the result of `Longx.Projects.Repo.git_changes`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
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
      ]

    def graphql_type(_), do: :git_changes
  end

  defmodule RepoDiff do
    @moduledoc "`Longx.Projects.Repo.git_file_diff` and other actions returning `@diff`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          binary: [type: :boolean, allow_nil?: false],
          diff: [type: :string, allow_nil?: false]
        ]
      ]

    def graphql_type(_), do: :repo_diff
  end

  defmodule RepoSha do
    @moduledoc "`Longx.Projects.Repo.git_commit` and other actions returning `@sha`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [fields: [sha: [type: :string, allow_nil?: false]]]

    def graphql_type(_), do: :repo_sha
  end

  defmodule GitLog do
    @moduledoc "the result of `Longx.Projects.Repo.git_log`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          sha: [type: :string, allow_nil?: false],
          subject: [type: :string, allow_nil?: false],
          author: [type: :string, allow_nil?: false],
          email: [type: :string, allow_nil?: false],
          # ISO 8601 text
          at: [type: :string, allow_nil?: false]
        ]
      ]

    def graphql_type(_), do: :git_log
  end

  defmodule GitShow do
    @moduledoc "the result of `Longx.Projects.Repo.git_show`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          sha: [type: :string, allow_nil?: false],
          subject: [type: :string, allow_nil?: false],
          body: [type: :string, allow_nil?: false],
          author: [type: :string, allow_nil?: false],
          email: [type: :string, allow_nil?: false],
          at: [type: :string, allow_nil?: false],
          parents: [type: {:array, :string}, allow_nil?: false],
          files: [type: {:array, :map}, allow_nil?: false]
        ]
      ]

    def graphql_type(_), do: :git_show
  end

  defmodule GitFileVersions do
    @moduledoc "the result of `Longx.Projects.Repo.git_file_versions`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          before: [type: :string],
          after: [type: :string],
          binary: [type: :boolean, allow_nil?: false]
        ]
      ]

    def graphql_type(_), do: :git_file_versions
  end

  defmodule GitBranches do
    @moduledoc "the result of `Longx.Projects.Repo.git_branches`"
    use Ash.Type.NewType,
      subtype_of: :map,
      constraints: [
        fields: [
          current: [type: :string],
          branches: [type: {:array, :map}, allow_nil?: false],
          stashes: [type: {:array, :map}, allow_nil?: false]
        ]
      ]

    def graphql_type(_), do: :git_branches
  end
end
