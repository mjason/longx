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

  # a provider's bare "Bad Request" said nothing of what was sent (LONX-C): the
  # failed turn's report carries that turn's model requests as the request log
  # keeps them (in memory, gone at a restart) — the shape, never the content
  test "a failed turn's report carries its model requests: model, provider, sizes, tools, status, error",
       %{dsn: dsn} do
    {:ok, _} = Reporting.set_dsn(dsn)
    Longx.AI.Gateway.Log.clear()

    body = %{
      "model" => "longx",
      "input" => [
        %{"role" => "user", "content" => [%{"type" => "input_text", "text" => "the secret plan"}]}
      ],
      "tools" => [%{"type" => "function", "name" => "exec_command"}],
      "reasoning" => %{"effort" => "low"},
      "client_metadata" => %{"thread_id" => "native_9", "turn_id" => "turn_9"}
    }

    id = Longx.AI.Gateway.Log.begin(body, %{upstream_id: "spark-x2.5", provider: "spark"})
    :ok = Longx.AI.Gateway.Log.finish(id, %{status: 200, error: "the model failed: Bad Request"})

    Reporting.turn_failed(
      "native_9",
      "turn_9",
      "model spark-x2.5 failed: spark-x2.5 (spark): the model failed: Bad Request"
    )

    envelope = await_envelope(~r/turn_9/)
    assert envelope =~ "model_requests"
    assert envelope =~ "spark-x2.5"
    assert envelope =~ "exec_command"
    assert envelope =~ "input_items"
    # the shape of what was sent, never what it said
    refute envelope =~ "the secret plan"
  end

  test "a test event, a fault and a failed turn reach the server named by the DSN", %{dsn: dsn} do
    {:ok, _} = Reporting.set_dsn(dsn)

    assert {:ok, _id} = Reporting.send_test()
    assert await_envelope(~r/Longx/)

    Reporting.fault(:socket_encode, "thread:x", "could not encode")
    assert await_envelope(~r/socket_encode/) =~ "could not encode"

    Reporting.turn_failed("native_1", "turn_1", "the model call crashed: boom")
    assert await_envelope(~r/turn_1/) =~ "boom"

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

    refute_envelope(~r/turn_2|turn_3/)

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

    refute_envelope(~r/Read timeout|TransportError/)
    Sentry.capture_exception(%RuntimeError{message: "a real one"}, result: :sync)
    assert await_envelope(~r/a real one/)

    # off again: nothing goes out
    {:ok, nil} = Reporting.set_dsn("")
    Reporting.fault(:socket_encode, "thread:y", "quiet")
    refute_envelope(~r/thread:y/)
  end

  # no envelope saying this within the window; any other (a crash report of a
  # process some earlier test left stopping — a Bypass instance, once — which
  # the logger handler sends while a DSN is set) is not what is refused here
  defp refute_envelope(pattern, deadline \\ System.monotonic_time(:millisecond) + 300) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:envelope, body} ->
        refute body =~ pattern
        refute_envelope(pattern, deadline)
    after
      left -> :ok
    end
  end

  # the envelope that says this, whatever else the SDK sent first (the events
  # go out from its own process; an earlier one can land after its test moved on)
  defp await_envelope(pattern, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:envelope, body} -> if body =~ pattern, do: body, else: await_envelope(pattern, deadline)
    after
      left -> flunk("no envelope matching #{inspect(pattern)}")
    end
  end
end
