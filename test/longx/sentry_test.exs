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

    # a provider's refusal of the prompt or the account (a content filter, a spent
    # quota) is the provider's word, not a bug of ours: the page tells the person,
    # Sentry hears nothing
    Reporting.turn_failed(
      "native_1",
      "turn_2",
      "model gpt-5.6-sol failed: gpt-5.6-sol (ls): upstream answered 502: Invalid prompt: your prompt was flagged as potentially violating our usage policy."
    )

    Reporting.turn_failed(
      "native_1",
      "turn_3",
      "model x failed: upstream answered 429: quota exhausted"
    )

    refute_receive {:envelope, _}, 300

    # a client's own protocol error (a connection opened and never used, a
    # malformed request, a closed socket) is not a bug of ours: dropped before
    # it goes out; a real exception still goes
    Sentry.capture_exception(
      %Bandit.HTTPError{message: "Read timeout", plug_status: :request_timeout},
      result: :sync
    )

    Sentry.capture_exception(%Bandit.TransportError{message: "closed", error: :closed},
      result: :sync
    )

    refute_receive {:envelope, _}, 300
    Sentry.capture_exception(%RuntimeError{message: "a real one"}, result: :sync)
    assert_receive {:envelope, body}, 5_000
    assert body =~ "a real one"

    # off again: nothing goes out
    {:ok, nil} = Reporting.set_dsn("")
    Reporting.fault(:socket_encode, "thread:y", "quiet")
    refute_receive {:envelope, _}, 300
  end
end
