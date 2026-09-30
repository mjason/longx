defmodule LongxWeb.WorkspaceUploadController do
  @moduledoc """
  `POST /uploads/:project_id` (multipart, fields `path` and `file`): copies
  a file into an existing directory in the project's working tree. Existing
  entries are never overwritten.
  """

  use LongxWeb, :controller

  alias Longx.Projects
  alias Longx.Projects.Workspace

  def create(conn, %{
        "project_id" => project_id,
        "path" => parent,
        "file" => %Plug.Upload{path: source, filename: filename}
      }) do
    case fetch_project(project_id) do
      {:ok, project} ->
        name = safe_name(filename)
        path = if(parent == "", do: name, else: Path.join(parent, name))
        upload_to(conn, project, path, source)

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "no such project"})
    end
  end

  def create(conn, _params),
    do: conn |> put_status(400) |> json(%{error: "path and file are required"})

  defp fetch_project(id) do
    case Ash.get(Projects.Project, id, authorize?: false) do
      {:ok, project} -> {:ok, project}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp upload_to(conn, project, path, source) do
    case Workspace.upload(project.root_path, path, source) do
      {:ok, entry} ->
        conn
        |> put_status(:created)
        |> json(%{
          path: entry.path,
          name: entry.name,
          kind: entry.kind,
          size: entry.size
        })

      {:error, :exists} ->
        conn |> put_status(409) |> json(%{error: "an entry with this name already exists"})

      {:error, reason} ->
        conn |> put_status(400) |> json(%{error: inspect(reason)})
    end
  end

  defp safe_name(name) do
    safe =
      name
      |> String.replace("\\", "/")
      |> Path.basename()
      |> String.replace(~r/[\x00-\x1f]/, "")
      |> String.trim()

    if safe in ["", ".", ".."], do: "upload", else: safe
  end
end
