defmodule LongxWeb.AttachmentControllerTest do
  @moduledoc """
  The composer's file attachments (a zip, a PDF, a dataset — anything the
  image and text adapters do not inline) are uploaded here and land in the
  project's attachment directory; the message then names the path, which a
  sandboxed command can read (`/` is read-only there) but never delete.
  """
  use LongxWeb.ConnCase, async: false

  alias Longx.Projects

  setup do
    Ash.bulk_destroy!(Projects.Turn, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(Projects.Thread, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(Projects.Project, :destroy, %{}, authorize?: false)
    dir = Path.join(System.tmp_dir!(), "longx-att-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, project} = Projects.create_project(%{name: "Att", root_path: dir})
    on_exit(fn -> File.rm_rf!(Projects.Attachments.dir(project.id)) end)
    %{project: project, dir: dir}
  end

  defp upload(conn, project_id, name, content, type \\ "application/zip") do
    file = Path.join(System.tmp_dir!(), "longx-up-#{System.unique_integer([:positive])}")
    File.write!(file, content)

    conn
    |> post("/attachments/#{project_id}", %{
      "file" => %Plug.Upload{path: file, filename: name, content_type: type}
    })
  end

  test "a file lands under the project's attachment directory with its name kept, the message gets the path",
       %{conn: conn, project: project} do
    conn = upload(conn, project.id, "数据 v2.zip", "PK\x03\x04zip-bytes")
    assert %{"path" => path, "name" => "数据 v2.zip", "bytes" => 13} = json_response(conn, 200)
    assert String.starts_with?(path, Projects.Attachments.dir(project.id))
    assert Path.basename(path) =~ ~r/^\d{8}T\d{6}-数据 v2\.zip$/
    assert File.read!(path) == "PK\x03\x04zip-bytes"
    # never inside the working directory: the repository stays clean
    refute String.starts_with?(path, project.root_path)
  end

  test "the name is a file name, never a path; an empty name gets one", %{
    conn: conn,
    project: project
  } do
    assert %{"path" => path} =
             json_response(upload(conn, project.id, "../../etc/passwd", "x"), 200)

    assert Path.basename(path) =~ ~r/-passwd$/
    assert Path.dirname(path) == Projects.Attachments.dir(project.id)
    assert %{"path" => path} = json_response(upload(conn, project.id, "", "x"), 200)
    assert Path.basename(path) =~ ~r/-attachment$/
  end

  test "an unknown project is 404; no file, no upload is 400", %{conn: conn, project: project} do
    assert json_response(upload(conn, Ash.UUID.generate(), "a.zip", "x"), 404)
    assert json_response(post(conn, "/attachments/#{project.id}", %{}), 400)
  end

  test "deleting the project removes its attachments", %{conn: conn, project: project} do
    %{"path" => path} = json_response(upload(conn, project.id, "a.zip", "x"), 200)
    assert File.exists?(path)
    :ok = Projects.delete_project(project, confirm: true)
    refute File.exists?(Projects.Attachments.dir(project.id))
  end
end
