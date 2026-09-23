defmodule LongxWeb.FileRulesRpcTest do
  @moduledoc """
  What Longx ignores in a project, on the wire: the global rules (Settings →
  文件监控), a project's own (`update_project` `fileRules`) and the list the
  file tree dims (`ignored_paths`).
  """
  use LongxWeb.ConnCase, async: false

  alias Longx.Projects

  setup do
    Ash.bulk_destroy!(Longx.System.Setting, :destroy, %{}, authorize?: false)
    dir = Path.join(System.tmp_dir!(), "longx-rulesrpc-#{System.unique_integer([:positive])}")

    for {rel, content} <- [
          {"src/a.py", ""},
          {"node_modules/x/y.js", ""},
          {"logs/today.txt", ""},
          {"README.md", ""}
        ] do
      File.mkdir_p!(Path.dirname(Path.join(dir, rel)))
      File.write!(Path.join(dir, rel), content)
    end

    on_exit(fn -> File.rm_rf!(dir) end)

    project =
      Projects.create_project!(%{
        name: "Rules #{System.unique_integer([:positive])}",
        root_path: dir
      })

    %{dir: dir, project: project}
  end

  defp rpc(conn, action, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/rpc/run", Jason.encode!(Map.put(params, "action", action)))
    |> json_response(200)
  end

  @fields ["ignore", "watch", "builtinIgnore", "builtinWatch"]

  test "the global rules: the built-in lists beside the saved texts", %{conn: conn} do
    assert %{"success" => true, "data" => data} = rpc(conn, "file_rules", %{"fields" => @fields})
    assert data["ignore"] == "" and data["watch"] == ""
    assert "node_modules/" in data["builtinIgnore"]
    assert ".longx/" in data["builtinWatch"]

    assert %{"success" => true, "data" => %{"ignore" => "logs/\n", "watch" => ""}} =
             rpc(conn, "set_file_rules", %{
               "fields" => @fields,
               "input" => %{"ignore" => "logs/\n", "watch" => ""}
             })

    assert %{"data" => %{"ignore" => "logs/\n"}} = rpc(conn, "file_rules", %{"fields" => @fields})
  end

  test "ignored_paths stacks the layers: built in, global, the project's, .longxignore",
       %{conn: conn, dir: dir, project: project} do
    list = fn ->
      assert %{"success" => true, "data" => paths} =
               rpc(conn, "ignored_paths", %{"input" => %{"projectId" => project.id}})

      paths
    end

    assert list.() == ["node_modules/"]

    rpc(conn, "set_file_rules", %{"fields" => @fields, "input" => %{"ignore" => "logs/"}})
    assert list.() == ["logs/", "node_modules/"]

    assert %{"success" => true, "data" => %{"fileRules" => %{"ignore" => "README.md"}}} =
             rpc(conn, "update_project", %{
               "fields" => ["fileRules"],
               "identity" => project.id,
               "input" => %{"fileRules" => %{"ignore" => "README.md", "watch" => ""}}
             })

    assert list.() == ["README.md", "logs/", "node_modules/"]

    File.write!(Path.join(dir, ".longxignore"), "!logs/\n")
    assert list.() == ["README.md", "node_modules/"]
  end

  test "ignored_paths of an unknown project is an error on projectId", %{conn: conn} do
    assert %{"success" => false, "errors" => [error | _]} =
             rpc(conn, "ignored_paths", %{"input" => %{"projectId" => Ash.UUID.generate()}})

    assert "projectId" in error["fields"]
  end
end
