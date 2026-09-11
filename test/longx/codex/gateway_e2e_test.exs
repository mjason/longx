defmodule Longx.Codex.GatewayE2ETest do
  @moduledoc """
  The whole chain: bundled codex-app-server → our /ai/v1/responses → upstream.

  Upstream is a Bypass returning a canned stream. Excluded by default:
  `mix test --include integration`. See `Longx.Codex.GatewayLiveTest` for the
  same flow against the real DeepSeek.
  """
  use Longx.DataCase, async: false

  alias Longx.AI
  alias Longx.Codex.Home
  alias Longx.Test.{CodexClient, ResponsesFixture}

  @moduletag :integration
  @moduletag timeout: 120_000

  setup do
    Ash.bulk_destroy!(AI.Model, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(AI.Provider, :destroy, %{}, authorize?: false)

    # Serve the real endpoint on a loopback port for codex to call.
    {:ok, bandit} =
      start_supervised(
        {Bandit, plug: LongxWeb.Endpoint, scheme: :http, ip: {127, 0, 0, 1}, port: 0}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)

    home_dir =
      Path.join(Path.expand("data"), "codex_home_e2e_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(home_dir) end)
    {:ok, home} = Home.prepare(dir: home_dir, gateway_url: "http://127.0.0.1:#{port}/ai/v1")

    %{home: home}
  end

  test "a turn completes through the gateway with the configured upstream model", %{home: home} do
    bypass = Bypass.open()
    test_pid = self()

    provider =
      AI.create_provider!(%{
        name: "Fake",
        slug: "fake-#{System.unique_integer([:positive])}",
        base_url: "http://localhost:#{bypass.port}/v1",
        api_key: "sk-fake"
      })

    AI.create_model!(%{name: "Fake", upstream_id: "fake-model", provider_id: provider.id})
    |> AI.make_default_model!()

    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn, length: 50_000_000)
      send(test_pid, {:upstream_request, conn.req_headers, Jason.decode!(raw)})

      conn =
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)

      Enum.reduce(
        ResponsesFixture.assistant_message("Hello from the fake upstream."),
        conn,
        fn frame, conn ->
          {:ok, conn} = Plug.Conn.chunk(conn, frame)
          conn
        end
      )
    end)

    {shim, thread_id} = CodexClient.start_thread(home)
    turn = CodexClient.run_turn(shim, thread_id, "hi")

    assert turn["status"] == "completed", "turn did not complete: #{inspect(turn)}"
    assert_received {:agent_message, "Hello from the fake upstream."}

    assert_receive {:upstream_request, headers, body}, 5_000
    assert {"authorization", "Bearer sk-fake"} in headers
    # codex's own routing headers stay between codex and the gateway
    refute List.keymember?(headers, "thread-id", 0)
    assert body["model"] == "fake-model"
    assert body["client_metadata"] == nil
    assert is_binary(thread_id)
    assert body["stream"] == true
    assert Enum.all?(body["tools"], &(&1["type"] == "function"))

    CodexClient.stop(shim)
  end
end
