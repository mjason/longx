defmodule LongxWeb.SentryRpcTest do
  @moduledoc "Error reporting on the wire: the status, the DSN saved and cleared, a test event."
  use LongxWeb.ConnCase, async: false

  defp rpc(conn, action, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/rpc/run", Jason.encode!(Map.put(params, "action", action)))
    |> json_response(200)
  end

  setup do
    Ash.bulk_destroy!(Longx.System.Setting, :destroy, %{}, authorize?: false)
    Longx.Sentry.set_dsn("")
    bypass = Bypass.open()
    Bypass.stub(bypass, "POST", "/api/3/envelope/", &Plug.Conn.resp(&1, 200, ~s({"id":"e"})))
    on_exit(fn -> Longx.Sentry.set_dsn("") end)
    %{dsn: "http://k@localhost:#{bypass.port}/3"}
  end

  @fields ~w(enabled dsn environment release)

  test "off until a DSN is saved; a bad one is an error on the field; a test event; cleared", %{
    conn: conn,
    dsn: dsn
  } do
    assert %{
             "success" => true,
             "data" => %{"enabled" => false, "dsn" => nil, "environment" => "test"}
           } =
             rpc(conn, "sentry_status", %{"fields" => @fields})

    assert %{"success" => false, "errors" => [%{"fields" => ["dsn"]}]} =
             rpc(conn, "set_sentry_dsn", %{"fields" => @fields, "input" => %{"dsn" => "nope"}})

    assert %{"success" => true, "data" => %{"enabled" => true, "dsn" => "http://***@" <> _}} =
             rpc(conn, "set_sentry_dsn", %{"fields" => @fields, "input" => %{"dsn" => dsn}})

    assert %{"success" => true, "data" => %{"ok" => true}} =
             rpc(conn, "sentry_test", %{"fields" => ~w(ok message)})

    assert %{"success" => true, "data" => %{"enabled" => false}} =
             rpc(conn, "set_sentry_dsn", %{"fields" => @fields, "input" => %{"dsn" => ""}})

    assert %{"success" => true, "data" => %{"ok" => false, "message" => "no DSN set"}} =
             rpc(conn, "sentry_test", %{"fields" => ~w(ok message)})
  end
end
