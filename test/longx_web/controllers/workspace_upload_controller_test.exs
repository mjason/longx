defmodule LongxWeb.WorkspaceUploadControllerTest do
  use LongxWeb.ConnCase, async: false

  alias Longx.Projects

  setup do
    root =
      Path.join(System.tmp_dir!(), "longx-workspace-upload-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "docs"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, project} = Projects.create_project(%{name: "Upload", root_path: root})
    %{project: project, root: root}
  end

  defp post_upload(conn, project_id, directory, name, bytes) do
    source = Path.join(System.tmp_dir!(), "longx-upload-#{System.unique_integer([:positive])}")
    File.write!(source, bytes)

    post(conn, "/uploads/#{project_id}", %{
      "path" => directory,
      "file" => %Plug.Upload{
        path: source,
        filename: name,
        content_type: "application/octet-stream"
      }
    })
  end

  test "uploads binary bytes into the chosen project directory and returns the entry", %{
    conn: conn,
    project: project,
    root: root
  } do
    conn = post_upload(conn, project.id, "docs", "chart.bin", <<0, 1, 255>>)

    assert %{"path" => "docs/chart.bin", "name" => "chart.bin", "size" => 3} =
             json_response(conn, 201)

    assert File.read!(Path.join(root, "docs/chart.bin")) == <<0, 1, 255>>
  end

  test "uses only the uploaded filename and refuses overwrite", %{
    conn: conn,
    project: project,
    root: root
  } do
    assert %{"path" => "docs/report.csv"} =
             json_response(post_upload(conn, project.id, "docs", "../../report.csv", "one"), 201)

    assert %{"error" => _} =
             json_response(post_upload(conn, project.id, "docs", "report.csv", "two"), 409)

    assert File.read!(Path.join(root, "docs/report.csv")) == "one"
  end

  test "rejects unknown projects and paths outside the root or into a missing directory", %{
    conn: conn,
    project: project
  } do
    assert json_response(post_upload(conn, Ash.UUID.generate(), "", "a.bin", "x"), 404)
    assert json_response(post_upload(conn, project.id, "../outside", "a.bin", "x"), 400)
    assert json_response(post_upload(conn, project.id, "missing", "a.bin", "x"), 400)
    assert json_response(post(conn, "/uploads/#{project.id}", %{"path" => ""}), 400)
  end
end
