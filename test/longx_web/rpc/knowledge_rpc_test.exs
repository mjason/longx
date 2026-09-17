defmodule LongxWeb.KnowledgeRpcTest do
  @moduledoc "The native kernel's global knowledge on the wire: list, read, write, delete."
  use LongxWeb.ConnCase, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "longx-knowrpc-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:longx, Longx.Agent.Loader, [])
    Application.put_env(:longx, Longx.Agent.Loader, Keyword.put(previous, :global_dir, dir))

    on_exit(fn ->
      Application.put_env(:longx, Longx.Agent.Loader, previous)
      Longx.Test.TmpDirs.rm_rf!(dir)
    end)

    :ok
  end

  defp rpc(conn, action, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/rpc/run", Jason.encode!(Map.put(params, "action", action)))
    |> json_response(200)
  end

  @fields ["root", "path", "title", "summary", "tags", "always", "writable"]

  test "list → write → read → delete; the shipped root is listed read-only", %{conn: conn} do
    assert %{"success" => true, "data" => docs} =
             rpc(conn, "knowledge_docs", %{"fields" => @fields})

    assert Enum.any?(docs, &(&1["root"] == "longx" and &1["writable"] == false))
    refute Enum.any?(docs, &(&1["root"] == "global"))

    content =
      "---\ntitle: Me\nsummary: how I like things\ntags: [me]\nalways: true\n---\nTabs, never spaces.\n"

    assert %{"success" => true} =
             rpc(conn, "knowledge_write", %{
               "input" => %{"path" => "global/me/profile.md", "content" => content}
             })

    assert %{"success" => true, "data" => docs} =
             rpc(conn, "knowledge_docs", %{"fields" => @fields})

    assert %{"title" => "Me", "always" => true, "tags" => ["me"], "writable" => true} =
             Enum.find(docs, &(&1["path"] == "global/me/profile.md"))

    assert %{"success" => true, "data" => %{"text" => ^content}} =
             rpc(conn, "knowledge_read", %{
               "fields" => ["text"],
               "input" => %{"path" => "global/me/profile.md"}
             })

    assert %{"success" => false, "errors" => [%{"fields" => ["content"]}]} =
             rpc(conn, "knowledge_write", %{
               "input" => %{"path" => "global/me/bad.md", "content" => "no front matter"}
             })

    assert %{"success" => false, "errors" => [%{"fields" => ["content"]}]} =
             rpc(conn, "knowledge_write", %{
               "input" => %{"path" => "longx/x.md", "content" => content}
             })

    assert %{"success" => true} =
             rpc(conn, "knowledge_delete", %{"input" => %{"path" => "global/me/profile.md"}})

    assert %{"success" => true, "data" => docs} =
             rpc(conn, "knowledge_docs", %{"fields" => @fields})

    refute Enum.any?(docs, &(&1["path"] == "global/me/profile.md"))

    assert %{"success" => false} =
             rpc(conn, "knowledge_read", %{
               "fields" => ["text"],
               "input" => %{"path" => "global/me/profile.md"}
             })
  end
end
