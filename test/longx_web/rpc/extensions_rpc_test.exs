defmodule LongxWeb.ExtensionsRpcTest do
  use LongxWeb.ConnCase, async: false
  alias Longx.Projects

  setup do
    root =
      Path.join(System.tmp_dir!(), "longx-extension-wire-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, ".longx/local/agents/helper"))
    File.write!(Path.join(root, ".longx/local/agents/helper/agent.exs"), "agent do end")
    File.write!(Path.join(root, ".longx/local/agents/helper/prompt.md"), "role prompt")
    project = Projects.create_project!(%{name: "Wire extensions", root_path: root})
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, project: project}
  end

  test "GraphQL selects inventory, review files and confirms a content-bound promotion", %{
    conn: conn,
    project: project,
    root: root
  } do
    query = """
    query($id: ID!) {
      extensionInventory(id: $id) { kind layer name path shareable complete }
    }
    """

    assert %{"data" => %{"extensionInventory" => [%{"name" => "helper", "kind" => "agents"}]}} =
             conn
             |> post("/gql", %{query: query, variables: %{id: project.id}})
             |> json_response(200)

    preview = """
    query($id: ID!, $path: String!) {
      previewLocal(id: $id, path: $path) {
        path target digest canShare conflicts
        files { source target content binary size hash truncated }
      }
    }
    """

    assert %{
             "data" => %{
               "previewLocal" => %{"digest" => digest, "canShare" => true, "files" => files}
             }
           } =
             conn
             |> post("/gql", %{
               query: preview,
               variables: %{id: project.id, path: "agents/helper"}
             })
             |> json_response(200)

    assert length(files) == 2

    mutation = """
    mutation($input: PromoteLocalInput!) {
      promoteLocal(input: $input) { path }
    }
    """

    assert %{"data" => %{"promoteLocal" => %{"path" => "shared/agents/helper"}}} =
             conn
             |> post("/gql", %{
               query: mutation,
               variables: %{input: %{id: project.id, path: "agents/helper", digest: digest}}
             })
             |> json_response(200)

    assert File.read!(Path.join(root, ".longx/shared/agents/helper/prompt.md")) == "role prompt"
  end

  test "wire rejects missing review and arbitrary artifacts", %{conn: conn, project: project} do
    assert %{"success" => false} =
             rpc(conn, "promote_local", %{
               "input" => %{"id" => project.id, "path" => "agents/helper"},
               "fields" => ["path"]
             })

    assert %{"success" => false} =
             rpc(conn, "preview_local", %{
               "input" => %{"id" => project.id, "path" => "artifacts/test.db"},
               "fields" => ["path"]
             })
  end
end
