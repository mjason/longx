defmodule Longx.AI.ProbeTest do
  use ExUnit.Case, async: true
  alias Longx.AI.{Probe, Target}

  setup do
    bypass = Bypass.open()

    target = %Target{
      model: "model",
      base_url: "http://localhost:#{bypass.port}/backend-api/codex",
      api_key: "synthetic-token",
      context_window: 128_000,
      chatgpt?: true,
      account_id: "synthetic-account",
      levels: ["low", "high"],
      default_effort: "high",
      max_output_tokens: 100_000,
      image_generation?: true
    }

    %{bypass: bypass, target: target}
  end

  defp sse(type, response),
    do: "event: #{type}\ndata: #{Jason.encode!(%{type: type, response: response})}\n\n"

  defp answer(conn, body),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, body)

  test "Codex check uses the conversation adapter, list input and a completed SSE response", %{
    bypass: bypass,
    target: target
  } do
    Bypass.expect_once(bypass, "POST", "/backend-api/codex/responses", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      assert is_list(body["input"])
      assert body["stream"] == true
      assert body["store"] == false
      assert is_binary(body["instructions"])
      refute Map.has_key?(body, "max_output_tokens")
      assert body["tools"] == []
      assert body["reasoning"]["effort"] == "low"
      assert {"originator", "codex_cli_rs"} in conn.req_headers
      assert {"chatgpt-account-id", "synthetic-account"} in conn.req_headers
      answer(conn, sse("response.completed", %{status: "completed", output: []}))
    end)

    assert {:ok, %{latency_ms: _}} = Probe.run(target)
  end

  test "HTTP 200 with a failed response is not a successful model check", %{
    bypass: bypass,
    target: target
  } do
    Bypass.expect_once(bypass, "POST", "/backend-api/codex/responses", fn conn ->
      answer(
        conn,
        sse("response.failed", %{status: "failed", error: %{message: "model not allowed"}})
      )
    end)

    assert {:error, {:status, 200, "model not allowed"}} = Probe.run(target)
  end

  test "split CRLF data-only SSE is accepted only at a successful terminal", %{
    bypass: bypass,
    target: target
  } do
    Bypass.expect_once(bypass, "POST", "/backend-api/codex/responses", fn conn ->
      conn =
        Plug.Conn.put_resp_content_type(conn, "text/event-stream") |> Plug.Conn.send_chunked(200)

      data =
        "data: " <>
          Jason.encode!(%{type: "response.completed", response: %{status: "completed"}}) <>
          "\r\n\r\n"

      <<first::binary-size(13), rest::binary>> = data
      {:ok, conn} = Plug.Conn.chunk(conn, first)
      {:ok, conn} = Plug.Conn.chunk(conn, rest)
      conn
    end)

    assert {:ok, _} = Probe.run(target)
    Bypass.down(bypass)
  end

  test "error, incomplete, empty JSON and a falsely labelled completed event do not pass", %{
    bypass: bypass,
    target: target
  } do
    for {content_type, body} <- [
          {"text/event-stream", "event: error\ndata: {\"message\":\"fixture failure\"}\n\n"},
          {"text/event-stream", sse("response.incomplete", %{status: "incomplete"})},
          {"text/event-stream", sse("response.completed", %{status: "in_progress"})},
          {"application/json", "{}"}
        ] do
      Bypass.expect_once(bypass, "POST", "/backend-api/codex/responses", fn conn ->
        conn |> Plug.Conn.put_resp_content_type(content_type) |> Plug.Conn.send_resp(200, body)
      end)

      assert {:error, {:status, 200, _}} = Probe.run(target)
    end
  end

  test "a truncated stream or DONE without completion fails", %{bypass: bypass, target: target} do
    Bypass.expect_once(bypass, "POST", "/backend-api/codex/responses", fn conn ->
      answer(conn, "data: [DONE]\n\n")
    end)

    assert {:error, {:status, 200, message}} = Probe.run(target)
    assert message =~ "without a completed response"
  end

  test "JSON errors preserve the vendor's detail rather than an inspected map", %{
    bypass: bypass,
    target: target
  } do
    Bypass.expect_once(bypass, "POST", "/backend-api/codex/responses", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(400, ~s({"detail":"bad request"}))
    end)

    assert {:error, {:status, 400, "bad request"}} = Probe.run(target)
  end

  test "a failed JSON response with HTTP 200 also fails", %{bypass: bypass, target: target} do
    Bypass.expect_once(bypass, "POST", "/backend-api/codex/responses", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"status":"failed","error":{"message":"not allowed"}}))
    end)

    assert {:error, {:status, 200, "not allowed"}} = Probe.run(target)
  end

  test "oversized streams are cancelled at the byte budget", %{bypass: bypass, target: target} do
    Bypass.expect_once(bypass, "POST", "/backend-api/codex/responses", fn conn ->
      answer(conn, ": " <> String.duplicate("x", 2000) <> "\n\n")
    end)

    assert {:error, {:status, 200, message}} = Probe.run(target, max_bytes: 1000)
    assert message =~ "exceeded"
  end

  test "a stream is bounded by a total deadline, not just an idle timeout", %{
    bypass: bypass,
    target: target
  } do
    owner = self()

    Bypass.expect_once(bypass, "GET", "/backend-api/codex/warm", fn conn ->
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert {:ok, _} = Finch.request(Finch.build(:get, target.base_url <> "/warm"), Longx.AI.Finch)

    Bypass.expect_once(bypass, "POST", "/backend-api/codex/responses", fn conn ->
      send(owner, :stream_started)
      conn = Plug.Conn.send_chunked(conn, 200)

      Enum.reduce_while(1..100, conn, fn index, conn ->
        Process.sleep(10)

        case Plug.Conn.chunk(conn, ": heartbeat\n\n") do
          {:ok, conn} ->
            if index == 1, do: send(owner, :heartbeat_sent)
            {:cont, conn}

          {:error, _} ->
            {:halt, conn}
        end
      end)
    end)

    started = System.monotonic_time(:millisecond)
    assert {:error, {:unreachable, message}} = Probe.run(target, timeout: 500)
    assert_receive :stream_started
    assert_receive :heartbeat_sent
    assert message =~ "timed out"
    assert System.monotonic_time(:millisecond) - started < 2000
    # Cowboy may terminate a streaming Plug with :shutdown when its client
    # cancels. That is the expected result here, not a failed vendor assertion.
    # The explicit messages above prove this was an active streaming request.
    Bypass.pass(bypass)
    Bypass.down(bypass)
  end

  test "byte cancellation releases a single-connection pool for the next check", %{
    bypass: bypass,
    target: target
  } do
    pool = __MODULE__.SinglePool
    start_supervised!({Finch, name: pool, pools: %{default: [size: 1, count: 1]}})

    Bypass.expect_once(bypass, "POST", "/backend-api/codex/responses", fn conn ->
      answer(conn, String.duplicate("x", 2000))
    end)

    assert {:error, {:status, 200, _}} = Probe.run(target, finch: pool, max_bytes: 1000)

    Bypass.expect_once(bypass, "POST", "/backend-api/codex/responses", fn conn ->
      answer(conn, sse("response.completed", %{status: "completed"}))
    end)

    assert {:ok, _} = Probe.run(target, finch: pool, timeout: 2000)
  end
end
