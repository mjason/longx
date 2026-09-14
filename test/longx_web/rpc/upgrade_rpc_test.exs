defmodule LongxWeb.UpgradeRpcTest do
  @moduledoc "The version and its upgrade on the wire: status, check, token, apply."
  use LongxWeb.ConnCase, async: false

  alias Longx.Upgrade

  setup do
    bypass = Bypass.open()
    previous = Application.get_env(:longx, Upgrade, [])

    Application.put_env(:longx, Upgrade,
      repo: "mjason/longx",
      api_url: "http://127.0.0.1:#{bypass.port}",
      tick: nil
    )

    Upgrade.reset()

    on_exit(fn ->
      Application.put_env(:longx, Upgrade, previous)
      Upgrade.reset()
    end)

    %{bypass: bypass}
  end

  defp rpc(conn, action, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/rpc/run", Jason.encode!(Map.put(params, "action", action)))
    |> json_response(200)
  end

  @fields ~w(current installed latest available notesUrl checkedAt error stage message target hasGithubToken)

  test "status before any check, a check, the token, an apply outside an install", %{
    conn: conn,
    bypass: bypass
  } do
    current = Upgrade.current_version()

    assert %{
             "success" => true,
             "data" => %{
               "current" => ^current,
               "installed" => false,
               "latest" => nil,
               "available" => false,
               "checkedAt" => nil,
               "stage" => "idle",
               "hasGithubToken" => false
             }
           } = rpc(conn, "upgrade_status", %{"fields" => @fields})

    Bypass.expect_once(bypass, "GET", "/repos/mjason/longx/releases/latest", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer ghp_x"]

      Plug.Conn.resp(
        conn,
        200,
        Jason.encode!(%{tag_name: "v99.0.0", html_url: "https://x/notes", assets: []})
      )
    end)

    assert %{"success" => true, "data" => %{"hasGithubToken" => true}} =
             rpc(conn, "set_github_token", %{
               "fields" => @fields,
               "input" => %{"token" => "ghp_x"}
             })

    assert %{
             "success" => true,
             "data" => %{
               "latest" => "99.0.0",
               "available" => true,
               "notesUrl" => "https://x/notes",
               "checkedAt" => at,
               "error" => nil
             }
           } = rpc(conn, "upgrade_check", %{"fields" => @fields})

    assert is_binary(at)

    # the cached result comes back from status without a request
    assert %{"success" => true, "data" => %{"latest" => "99.0.0"}} =
             rpc(conn, "upgrade_status", %{"fields" => @fields})

    # not an install: the apply is refused with a message, the status untouched
    assert %{"success" => false, "errors" => [%{"message" => message}]} =
             rpc(conn, "upgrade_apply", %{"fields" => @fields})

    assert message =~ "安装"

    assert %{"success" => true, "data" => %{"hasGithubToken" => false}} =
             rpc(conn, "set_github_token", %{"fields" => @fields, "input" => %{"token" => ""}})

    # a failed check keeps the failure, not the old result
    Bypass.expect_once(bypass, "GET", "/repos/mjason/longx/releases/latest", fn conn ->
      Plug.Conn.resp(conn, 500, "")
    end)

    assert %{"success" => true, "data" => %{"latest" => nil, "error" => error}} =
             rpc(conn, "upgrade_check", %{"fields" => @fields})

    assert error =~ "500"
  end
end
