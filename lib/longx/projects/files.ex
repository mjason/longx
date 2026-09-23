defmodule Longx.Projects.Files do
  @moduledoc """
  A resource without data: the file tree and the editor, as generic actions
  over `Longx.Projects.Workspace` for one project (`project_id`). Paths are
  relative to the project root; anything outside it is refused with an
  error on `path`.
  """

  use Ash.Resource,
    otp_app: :longx,
    domain: Longx.Projects,
    extensions: [AshTypescript.Resource]

  alias Longx.Projects.Workspace

  typescript do
    type_name "ProjectFiles"
  end

  @entry [
    name: [type: :string, allow_nil?: false],
    path: [type: :string, allow_nil?: false],
    kind: [type: :atom, constraints: [one_of: [:file, :dir]], allow_nil?: false],
    size: [type: :integer, allow_nil?: false]
  ]

  actions do
    action :list_files, {:array, :map} do
      constraints items: [fields: @entry]
      argument :project_id, :uuid, allow_nil?: false
      argument :path, :string, allow_nil?: false, constraints: [allow_empty?: true]

      run fn input, _ ->
        with {:ok, root} <- root(input),
             do: Workspace.list(root, input.arguments.path) |> wrap(:path)
      end
    end

    action :read_file, :map do
      constraints fields: [
                    path: [type: :string, allow_nil?: false],
                    content: [type: :string],
                    size: [type: :integer, allow_nil?: false],
                    binary: [type: :boolean, allow_nil?: false],
                    truncated: [type: :boolean, allow_nil?: false]
                  ]

      argument :project_id, :uuid, allow_nil?: false
      argument :path, :string, allow_nil?: false

      run fn input, _ ->
        with {:ok, root} <- root(input),
             do: Workspace.read(root, input.arguments.path) |> wrap(:path)
      end
    end

    action :write_file do
      argument :project_id, :uuid, allow_nil?: false
      argument :path, :string, allow_nil?: false

      argument :content, :string,
        allow_nil?: false,
        constraints: [allow_empty?: true, trim?: false]

      run fn input, _ ->
        with {:ok, root} <- root(input),
             do:
               Workspace.write(root, input.arguments.path, input.arguments.content) |> wrap(:path)
      end
    end

    action :create_entry, :map do
      constraints fields: @entry
      argument :project_id, :uuid, allow_nil?: false
      argument :path, :string, allow_nil?: false
      argument :kind, :atom, constraints: [one_of: [:file, :dir]], allow_nil?: false

      run fn input, _ ->
        with {:ok, root} <- root(input),
             do: Workspace.create(root, input.arguments.path, input.arguments.kind) |> wrap(:path)
      end
    end

    action :rename_entry, :map do
      constraints fields: @entry
      argument :project_id, :uuid, allow_nil?: false
      argument :from, :string, allow_nil?: false
      argument :to, :string, allow_nil?: false

      run fn input, _ ->
        with {:ok, root} <- root(input),
             do: Workspace.rename(root, input.arguments.from, input.arguments.to) |> wrap(:to)
      end
    end

    # what the tree dims (Longx.Projects.FileRules: built in, global, the project's,
    # .gitignore, .longxignore): an ignored directory ends with "/"
    action :ignored_paths, {:array, :string} do
      argument :project_id, :uuid, allow_nil?: false

      run fn input, _ ->
        case Ash.get(Longx.Projects.Project, input.arguments.project_id) do
          {:ok, project} ->
            with {:ok, paths} <- Longx.Projects.FileRules.ignored(project),
                 do: {:ok, Enum.sort(paths)}

          {:error, _} ->
            wrap({:error, :unknown_project}, :project_id)
        end
      end
    end

    action :delete_entry do
      argument :project_id, :uuid, allow_nil?: false
      argument :path, :string, allow_nil?: false

      run fn input, _ ->
        with {:ok, root} <- root(input),
             do: Workspace.delete(root, input.arguments.path) |> wrap(:path)
      end
    end
  end

  defp root(input) do
    with {:ok, project} <- Ash.get(Longx.Projects.Project, input.arguments.project_id),
         do: {:ok, project.root_path}
  end

  @messages %{
    outside_root: "is outside the project",
    not_found: "does not exist",
    not_a_file: "is not a file",
    not_a_directory: "is not a directory",
    exists: "already exists",
    unknown_project: "is not a project"
  }

  defp wrap(:ok, _field), do: :ok
  defp wrap({:ok, _} = ok, _field), do: ok

  defp wrap({:error, reason}, field) do
    message = Map.get(@messages, reason) || "could not be accessed: #{inspect(reason)}"

    {:error,
     Ash.Error.to_error_class(
       Ash.Error.Changes.InvalidArgument.exception(field: field, message: message)
     )}
  end
end
