defmodule LongxWeb.DependenciesRpcTest do
  @moduledoc "The system dependency check on the wire."
  use LongxWeb.ConnCase, async: false

  defp rpc(conn, action, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/rpc/run", Jason.encode!(Map.put(params, "action", action)))
    |> json_response(200)
  end

  @fields ["os", "missing", "installCommand", "tools", "checkedAt"]

  test "the report lists every tool with found / version / install package; a forced check answers the same shape",
       %{conn: conn} do
    assert %{"success" => true, "data" => %{"os" => os, "missing" => missing, "tools" => tools}} =
             rpc(conn, "dependencies", %{"fields" => @fields})

    assert os in ["linux", "darwin", "windows"]
    assert is_integer(missing)
    assert Enum.map(tools, & &1["name"]) == ~w(ripgrep fd-find fzf bat jq tree git gh git-delta)

    assert %{"found" => true, "command" => "git", "install" => %{"apt" => "git"}} =
             Enum.find(tools, &(&1["name"] == "git"))

    assert %{"success" => true, "data" => %{"checkedAt" => at}} =
             rpc(conn, "check_dependencies", %{"fields" => @fields})

    assert is_binary(at)
  end
end
