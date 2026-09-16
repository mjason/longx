defmodule LongxWeb.MemoryRpcTest do
  @moduledoc "The global memory on the wire: index, notes, search — what a memory page will use."
  use LongxWeb.ConnCase, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "longx-memrpc-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:longx, Longx.Memory, [])
    Application.put_env(:longx, Longx.Memory, Keyword.put(previous, :dir, dir))

    on_exit(fn ->
      Application.put_env(:longx, Longx.Memory, previous)
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

  test "index → edit → notes → search → delete", %{conn: conn} do
    assert %{"success" => true, "data" => %{"text" => text}} =
             rpc(conn, "memory_index", %{"fields" => ["text"]})

    assert text =~ "# MEMORY"

    assert %{"success" => true} =
             rpc(conn, "memory_write_index", %{"input" => %{"text" => "# MEMORY\n\n- tabs\n"}})

    {:ok, file} = Longx.Memory.add_note(Longx.Memory.dir(), "spaces are bad", project: "p")

    assert %{
             "success" => true,
             "data" => [
               %{"file" => ^file, "project" => "p", "text" => "spaces are bad", "at" => at}
             ]
           } =
             rpc(conn, "memory_notes", %{"fields" => ["file", "project", "thread", "text", "at"]})

    assert is_binary(at)

    assert %{"success" => true, "data" => hits} =
             rpc(conn, "memory_search", %{
               "fields" => ["file", "line", "text"],
               "input" => %{"query" => "tabs"}
             })

    assert [%{"file" => "MEMORY.md", "line" => 3}] = hits

    assert %{
             "success" => true,
             "data" => %{"autoExtract" => true, "pending" => 1, "folded" => 0, "lastRunAt" => nil}
           } =
             rpc(conn, "memory_status", %{
               "fields" => ["autoExtract", "pending", "folded", "lastRunAt", "lastError"]
             })

    assert %{"success" => true} =
             rpc(conn, "memory_set_auto_extract", %{"input" => %{"enabled" => false}})

    assert %{"success" => true, "data" => %{"autoExtract" => false}} =
             rpc(conn, "memory_status", %{"fields" => ["autoExtract"]})

    assert %{"success" => true} = rpc(conn, "memory_run", %{})

    assert %{"success" => true} = rpc(conn, "memory_delete_note", %{"input" => %{"file" => file}})
    assert %{"success" => true, "data" => []} = rpc(conn, "memory_notes", %{"fields" => ["file"]})

    assert %{"success" => false} =
             rpc(conn, "memory_delete_note", %{"input" => %{"file" => "../x"}})
  end
end
