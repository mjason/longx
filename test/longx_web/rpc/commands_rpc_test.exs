defmodule LongxWeb.CommandsRpcTest do
  @moduledoc "The live commands on the wire: listed with their session, killed by id from the GUI."
  use LongxWeb.ConnCase, async: false

  defp rpc(conn, action, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/rpc/run", Jason.encode!(Map.put(params, "action", action)))
    |> json_response(200)
  end

  test "running_commands lists what runs; kill_command ends one and answers not_found afterwards",
       %{conn: conn} do
    me = self()

    spawn_link(fn ->
      :ok =
        Longx.System.Pressure.register(%{
          id: "cmd_wire",
          shim: nil,
          floor: 0,
          cmd: "uv run jbt run x",
          thread_id: "native_wire",
          started_at: System.system_time(:millisecond) - 1_000
        })

      send(me, :registered)

      receive do
        {:kill_command, _} -> send(me, :killed)
      end
    end)

    assert_receive :registered

    assert %{"success" => true, "data" => %{"commands" => commands}} =
             rpc(conn, "running_commands", %{"fields" => ["commands"]})

    assert %{
             "id" => "cmd_wire",
             "cmd" => "uv run jbt run x",
             "threadId" => "native_wire",
             "elapsedMs" => ms,
             "session" => nil
           } =
             Enum.find(commands, &(&1["id"] == "cmd_wire"))

    assert ms >= 1_000

    assert %{"success" => true, "data" => %{"ok" => true}} =
             rpc(conn, "kill_command", %{"fields" => ["ok"], "input" => %{"id" => "cmd_wire"}})

    assert_receive :killed

    assert %{"success" => false, "errors" => [%{"fields" => ["id"]}]} =
             rpc(conn, "kill_command", %{"fields" => ["ok"], "input" => %{"id" => "cmd_wire"}})
  end
end
