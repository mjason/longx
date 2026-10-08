defmodule LongxWeb.FileControllerTest do
  @moduledoc """
  `GET /files/:project_id/*path` hands the person a file of the project
  (`send_file` in the chat, an image drawn inline): only inside the root
  or the project's attachment directory, as a download unless `inline=1`.
  """
  use LongxWeb.ConnCase, async: false

  alias Longx.Projects

  setup do
    Ash.bulk_destroy!(Projects.Turn, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(Projects.Thread, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(Projects.Project, :destroy, %{}, authorize?: false)
    root = Path.join(System.tmp_dir!(), "longx-files-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "docs"))
    File.mkdir_p!(Path.join(root, ".git"))
    File.write!(Path.join(root, "docs/报表 v2.csv"), "a,b\n1,2\n")
    File.write!(Path.join(root, "logo.png"), <<137, 80, 78, 71>>)
    File.write!(Path.join(root, ".git/config"), "[core]\n")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, project} = Projects.create_project(%{name: "Files", root_path: root})

    previous = Application.get_env(:longx, Projects.Attachments, [])

    Application.put_env(
      :longx,
      Projects.Attachments,
      Keyword.put(previous, :dir, Path.join(root, "_att"))
    )

    on_exit(fn -> Application.put_env(:longx, Projects.Attachments, previous) end)

    {:ok, stored} =
      Projects.Attachments.store(project.id, Path.join(root, "logo.png"), "拖进来的.png")

    %{project: project, root: root, attachment: stored}
  end

  test "a file of the root comes as a download with its mime and name", %{conn: conn, project: p} do
    conn = get(conn, "/files/#{p.id}/docs/#{URI.encode("报表 v2.csv")}")
    assert conn.status == 200
    assert conn.resp_body == "a,b\n1,2\n"
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/csv"
    [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "attachment"
    assert disposition =~ URI.encode("报表 v2.csv")
  end

  test "inline=1 shows it in the browser instead (an image in the chat)", %{
    conn: conn,
    project: p
  } do
    conn = get(conn, "/files/#{p.id}/logo.png?inline=1")
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/png"]
    assert get_resp_header(conn, "content-disposition") |> hd() =~ "inline"
  end

  test "a text file is served as utf-8: a browser decodes an html without a charset by its locale",
       %{conn: conn, project: p, root: root} do
    File.write!(Path.join(root, "hello.html"), "<!doctype html><title>页面</title>")
    conn = get(conn, "/files/#{p.id}/hello.html?inline=1")
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/html; charset=utf-8"]
  end

  test "the attachment directory is reached under _attachments", %{
    conn: conn,
    project: p,
    attachment: a
  } do
    conn = get(conn, "/files/#{p.id}/_attachments/#{URI.encode(Path.basename(a.path))}")
    assert conn.status == 200
    assert conn.resp_body == <<137, 80, 78, 71>>
  end

  test "outside the root, .git, a directory, a missing file, an unknown project: 404", %{
    conn: conn,
    project: p
  } do
    for path <- [
          "../../etc/passwd",
          ".git/config",
          "docs",
          "nope.txt",
          "_attachments/../logo.png"
        ] do
      assert get(conn, "/files/#{p.id}/#{path}").status == 404, path
    end

    assert get(conn, "/files/#{Ash.UUID.generate()}/logo.png").status == 404
  end

  test "view_image exposes the exact viewed bytes through an attachment snapshot, not a local path",
       %{conn: conn, project: project, root: root} do
    alias Longx.Agent.{Context, Tool}
    alias Longx.Agent.Plugs.ViewImage
    alias Longx.Agent.Kernel.UI

    tool = Enum.find(ViewImage.__agent_tools__(), &(&1.name == "view_image"))
    ctx = %Context{cwd: root, project_id: project.id}
    source = root <> "-view.png"
    File.write!(source, <<137, 80, 78, 71>>)
    on_exit(fn -> File.rm(source) end)

    assert {:ok, text, %{"image" => image, "details" => details} = extra} =
             Tool.call(tool, %{"path" => source}, ctx)

    assert image == "data:image/png;base64," <> Base.encode64(<<137, 80, 78, 71>>)
    assert details["name"] == Path.basename(source)
    assert details["mime"] == "image/png"
    assert details["bytes"] == 4
    assert details["attachment"] == true
    refute Path.type(details["path"]) == :absolute
    refute Map.has_key?(details, "image")

    ui = UI.completed_ui(tool, "image-call", "turn", true, text, "", 10, extra)
    assert ui["namespace"] == "view_image"
    assert ui["details"] == details
    refute Jason.encode!(ui) =~ "base64"

    File.write!(source, "changed after viewing")

    result =
      get(conn, "/files/#{project.id}/_attachments/#{URI.encode(details["path"])}?inline=1")

    assert result.status == 200
    assert result.resp_body == <<137, 80, 78, 71>>
    assert get_resp_header(result, "content-type") == ["image/png"]
  end
end
