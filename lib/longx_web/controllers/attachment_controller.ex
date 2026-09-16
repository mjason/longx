defmodule LongxWeb.AttachmentController do
  @moduledoc """
  `POST /attachments/:project_id` (multipart, field `file`): the composer's
  file attachments — see `Longx.Projects.Attachments`. Answers
  `{path, name, bytes}` for the message to name.
  """

  use LongxWeb, :controller

  alias Longx.Projects
  alias Longx.Projects.Attachments

  def create(conn, %{"project_id" => project_id, "file" => %Plug.Upload{} = upload}) do
    with {:ok, project} <- fetch_project(project_id),
         {:ok, stored} <- Attachments.store(project.id, upload.path, upload.filename) do
      json(conn, %{path: stored.path, name: stored.name, bytes: stored.bytes})
    else
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "no such project"})
      {:error, reason} -> conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  def create(conn, _params), do: conn |> put_status(400) |> json(%{error: "file is required"})

  defp fetch_project(id) do
    case Ash.get(Projects.Project, id, authorize?: false) do
      {:ok, project} -> {:ok, project}
      {:error, _} -> {:error, :not_found}
    end
  end
end
