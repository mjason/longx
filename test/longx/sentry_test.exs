defmodule Longx.SentryTest do
  @moduledoc """
  Error reporting on demand: a DSN saved in the settings turns Sentry on,
  clearing it turns it off; a test event reaches the server named by the
  DSN; faults and failed turns are reported. Bypass plays Sentry.
  """
  use Longx.DataCase, async: false

  alias Longx.Sentry, as: Reporting

  setup do
    Ash.bulk_destroy!(Longx.System.Setting, :destroy, %{}, authorize?: false)
    bypass = Bypass.open()
    test = self()

    Bypass.stub(bypass, "POST", "/api/7/envelope/", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:envelope, body})
      Plug.Conn.resp(conn, 200, ~s({"id":"evt"}))
    end)

    on_exit(fn -> Reporting.set_dsn("") end)
    %{bypass: bypass, dsn: "http://public@localhost:#{bypass.port}/7"}
  end

  test "no DSN: off; a DSN saved turns reporting on, masked in the status; cleared turns it off",
       %{dsn: dsn} do
    assert %{enabled: false, dsn: nil} = Reporting.status()
    assert {:error, message} = Reporting.set_dsn("not a dsn")
    assert message =~ "DSN"
    assert %{enabled: false} = Reporting.status()

    assert {:ok, ^dsn} = Reporting.set_dsn(dsn)
    assert %{enabled: true, dsn: masked, environment: env, release: release} = Reporting.status()
    assert masked == "http://***@localhost:#{dsn |> URI.parse() |> Map.get(:port)}/7"
    assert is_binary(env) and is_binary(release)

    # a boot reads the setting back
    Sentry.put_config(:dsn, nil)
    assert :ok = Reporting.configure_from_settings()
    assert %{enabled: true} = Reporting.status()

    assert {:ok, nil} = Reporting.set_dsn("")
    assert %{enabled: false, dsn: nil} = Reporting.status()
    assert Reporting.send_test() == {:error, "no DSN set"}
  end

  test "a test event, a fault and a failed turn reach the server named by the DSN", %{dsn: dsn} do
    {:ok, _} = Reporting.set_dsn(dsn)

    assert {:ok, _id} = Reporting.send_test()
    assert_receive {:envelope, body}, 5_000
    assert body =~ "Longx"

    Reporting.fault(:socket_encode, "thread:x", "could not encode")
    assert_receive {:envelope, body}, 5_000
    assert body =~ "socket_encode"
    assert body =~ "could not encode"

    Reporting.turn_failed("native_1", "turn_1", "the model call crashed: boom")
    assert_receive {:envelope, body}, 5_000
    assert body =~ "turn_1"
    assert body =~ "boom"

    # off again: nothing goes out
    {:ok, nil} = Reporting.set_dsn("")
    Reporting.fault(:socket_encode, "thread:y", "quiet")
    refute_receive {:envelope, _}, 300
  end
end
