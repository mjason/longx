defmodule LongxWeb.FileController do
  @moduledoc """
  `GET /files/:project_id/*path`: a file of the project for the person —
  what `send_file` in the chat links to, an image the chat draws inline.
  The path is relative to the project root and resolved inside it
  (`Longx.Projects.Workspace.resolve/2`: `..`, absolute paths and `.git/`
  are refused); `_attachments/<name>` reaches the project's attachment
  directory instead. A download (`content-disposition: attachment`) unless
  `?inline=1`; the mime from the extension; 404 for anything else.

  No authentication today: Longx is single-user and this is the same
  boundary as the RPC and `POST /attachments` — whoever reaches the page
  reaches the files.
  """

  use LongxWeb, :controller

  alias Longx.Projects
  alias Longx.Projects.{Attachments, Workspace}

  def show(conn, %{"project_id" => project_id, "path" => segments} = params) do
    with {:ok, project} <- fetch_project(project_id),
         {:ok, full} <- locate(project, segments),
         true <- File.regular?(full) do
      send_download(conn, {:file, full},
        filename: Path.basename(full),
        content_type: MIME.from_path(full),
        disposition: if(params["inline"] in ["1", "true"], do: :inline, else: :attachment)
      )
    else
      _ -> conn |> put_status(404) |> text("not found")
    end
  end

  defp locate(project, ["_attachments", name]) when name not in [".", ".."],
    do: {:ok, Path.join(Attachments.dir(project.id), name)}

  defp locate(_project, ["_attachments" | _]), do: {:error, :outside_root}

  defp locate(project, segments) when is_list(segments) and segments != [],
    do: Workspace.resolve(project.root_path, Path.join(segments))

  defp locate(_project, _segments), do: {:error, :outside_root}

  defp fetch_project(id) do
    case Ash.get(Projects.Project, id, authorize?: false) do
      {:ok, project} -> {:ok, project}
      {:error, _} -> {:error, :not_found}
    end
  end
end
