defmodule LongxWeb.ShellEnvironmentRpcTest do
  use LongxWeb.ConnCase, async: false
  alias Longx.Agent.Tools.ShellEnv

  setup do
    Longx.Test.ShellEnvFixture.setup()
  end

  test "refresh returns only shell and timestamp and new commands use the new environment", %{
    conn: conn,
    shell: shell
  } do
    assert ShellEnv.env()["SHELL_REFRESH_VALUE"] == "first"
    File.write!(shell <> ".state", "second")

    assert %{"success" => true, "data" => %{"shell" => ^shell, "refreshedAt" => at} = data} =
             rpc(conn, "refresh_shell_environment", %{"fields" => ["shell", "refreshedAt"]})

    assert {:ok, _, _} = DateTime.from_iso8601(at)
    assert Enum.sort(Map.keys(data)) == ["refreshedAt", "shell"]
    assert ShellEnv.env()["SHELL_REFRESH_VALUE"] == "second"
    refute Jason.encode!(data) =~ "fixture-env-secret"
  end

  test "failed refresh is actionable and neither replaces the cache nor leaks stderr", %{
    conn: conn,
    shell: shell
  } do
    assert ShellEnv.env()["SHELL_REFRESH_VALUE"] == "first"
    File.write!(shell <> ".state", "fail")
    result = rpc(conn, "refresh_shell_environment", %{"fields" => ["shell", "refreshedAt"]})
    assert %{"success" => false, "errors" => [%{"message" => message} | _]} = result
    assert message =~ "snapshot was not changed"
    refute Jason.encode!(result) =~ "fixture-stderr-secret"
    assert ShellEnv.env()["SHELL_REFRESH_VALUE"] == "first"
  end

  test "the GraphQL return type has no environment field", %{conn: conn} do
    result =
      conn
      |> post("/gql", %{
        "query" => "mutation { refreshShellEnvironment { shell refreshedAt env } }"
      })
      |> json_response(200)

    assert %{"errors" => [_ | _]} = result
    refute Jason.encode!(result) =~ "fixture-env-secret"
  end
end
