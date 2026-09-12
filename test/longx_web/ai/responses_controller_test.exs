defmodule LongxWeb.AI.ResponsesControllerTest do
  use LongxWeb.ConnCase, async: false

  alias Longx.AI
  alias Longx.AI.Gateway.Token

  @path "/ai/v1/responses"

  @request %{
    "model" => "longx",
    "input" => [
      %{
        "type" => "message",
        "role" => "user",
        "content" => [%{"type" => "input_text", "text" => "hi"}]
      }
    ],
    "tools" => [
      %{"type" => "function", "name" => "exec_command", "parameters" => %{}},
      %{"type" => "web_search"}
    ],
    "stream" => true,
    "store" => false
  }

  @sse [
    ~s(event: response.created\ndata: {"type":"response.created","response":{"id":"resp_1"}}\n\n),
    ~s(event: response.output_text.delta\ndata: {"type":"response.output_text.delta","delta":"hel"}\n\n),
    ~s(event: response.output_text.delta\ndata: {"type":"response.output_text.delta","delta":"lo"}\n\n),
    ~s(event: response.completed\ndata: {"type":"response.completed","response":{"id":"resp_1","usage":{"input_tokens":1,"output_tokens":2}}}\n\n)
  ]

  setup do
    # seeds leave a default DeepSeek model behind; each test configures its own
    Ash.bulk_destroy!(AI.Model, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(AI.Provider, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(AI.SearchProvider, :destroy, %{}, authorize?: false)

    bypass = Bypass.open()
    n = System.unique_integer([:positive])

    provider =
      AI.create_provider!(%{
        name: "Upstream #{n}",
        slug: "upstream-#{n}",
        base_url: "http://localhost:#{bypass.port}/v1",
        api_key: "sk-upstream"
      })

    %{bypass: bypass, provider: provider}
  end

  defp configure_default!(provider, attrs \\ %{}) do
    model =
      AI.create_model!(
        Map.merge(%{name: "M", upstream_id: "real-model", provider_id: provider.id}, attrs)
      )

    AI.make_default_model!(model)
  end

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer #{Token.current()}")

  # codex sends exactly these two headers
  defp post_json(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "text/event-stream")
    |> post(@path, Jason.encode!(body))
  end

  describe "authentication" do
    test "rejects a missing bearer", %{conn: conn} do
      conn = post_json(conn, @request)
      assert json_response(conn, 401)["error"]["message"] =~ "gateway token"
    end

    test "rejects a wrong bearer", %{conn: conn} do
      conn = conn |> put_req_header("authorization", "Bearer nope") |> post_json(@request)
      assert response(conn, 401)
    end
  end

  describe "relay" do
    test "streams the upstream SSE through untouched", %{
      conn: conn,
      bypass: bypass,
      provider: provider
    } do
      configure_default!(provider)
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/v1/responses", fn up ->
        {:ok, raw, up} = Plug.Conn.read_body(up)
        send(test_pid, {:upstream, up.req_headers, Jason.decode!(raw)})

        up =
          up
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_chunked(200)

        Enum.reduce(@sse, up, fn frame, up ->
          {:ok, up} = Plug.Conn.chunk(up, frame)
          up
        end)
      end)

      conn = conn |> authed() |> post_json(@request)

      assert conn.status == 200
      assert conn.state == :chunked
      assert get_resp_header(conn, "content-type") |> hd() =~ "text/event-stream"
      assert conn.resp_body == Enum.join(@sse)

      assert_receive {:upstream, headers, body}
      assert {"authorization", "Bearer sk-upstream"} in headers
      assert body["model"] == "real-model"
      assert body["tools"] == @request["tools"]
    end

    test "passes upstream client errors through so codex can show them", %{
      conn: conn,
      bypass: bypass,
      provider: provider
    } do
      configure_default!(provider)

      Bypass.expect_once(bypass, "POST", "/v1/responses", fn up ->
        up
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          401,
          ~s({"error":{"message":"Authentication Fails","type":"authentication_error"}})
        )
      end)

      conn = conn |> authed() |> post_json(@request)
      assert json_response(conn, 401)["error"]["message"] == "Authentication Fails"
    end

    test "answers 502 when the upstream is unreachable", %{
      conn: conn,
      bypass: bypass,
      provider: provider
    } do
      configure_default!(provider)
      Bypass.down(bypass)

      conn = conn |> authed() |> post_json(@request)
      assert json_response(conn, 502)["error"]["message"] =~ "upstream"
    end
  end

  describe "model routing" do
    test "the model name codex sends selects the upstream model", %{
      conn: conn,
      bypass: bypass,
      provider: provider
    } do
      configure_default!(provider)

      other =
        AI.create_model!(%{
          name: "Other",
          upstream_id: "other-upstream",
          slug: "other-slug",
          provider_id: provider.id
        })

      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/v1/responses", fn up ->
        {:ok, raw, up} = Plug.Conn.read_body(up)
        send(test_pid, {:model, Jason.decode!(raw)["model"]})
        up |> Plug.Conn.put_resp_content_type("text/event-stream") |> Plug.Conn.send_chunked(200)
      end)

      conn |> authed() |> post_json(Map.put(@request, "model", other.slug))
      assert_receive {:model, "other-upstream"}
    end

    test "an unknown model name is a 400 codex can display", %{conn: conn, provider: provider} do
      configure_default!(provider)
      conn = conn |> authed() |> post_json(Map.put(@request, "model", "no-such-model"))
      assert json_response(conn, 400)["error"]["message"] =~ "no-such-model"
    end
  end

  describe "OpenAI degraded retry" do
    @reasoning_input [
      %{
        "type" => "message",
        "role" => "user",
        "content" => [%{"type" => "input_text", "text" => "hi"}]
      },
      %{
        "type" => "reasoning",
        "id" => "rs_old",
        "summary" => [%{"type" => "summary_text", "text" => "s"}],
        "encrypted_content" => "gAAAA-stale"
      }
    ]

    defp openai_provider!(bypass) do
      p =
        AI.create_provider!(%{
          name: "OpenAI",
          slug: "openai-#{System.unique_integer([:positive])}",
          kind: :openai,
          base_url: "http://localhost:#{bypass.port}/v1",
          api_key: "sk-oa"
        })

      configure_default!(p)
      p
    end

    test "an OpenAI 400 about encrypted reasoning is retried once with every encrypted_content stripped",
         %{conn: conn, bypass: bypass} do
      openai_provider!(bypass)
      test_pid = self()
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      Bypass.expect(bypass, "POST", "/v1/responses", fn up ->
        {:ok, raw, up} = Plug.Conn.read_body(up)
        n = Agent.get_and_update(calls, &{&1 + 1, &1 + 1})
        send(test_pid, {:attempt, n, Jason.decode!(raw)["input"]})

        case n do
          1 ->
            up
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              400,
              ~s({"error":{"message":"Invalid encrypted_content: could not decrypt reasoning item rs_old","type":"invalid_request_error"}})
            )

          _ ->
            up =
              up
              |> Plug.Conn.put_resp_content_type("text/event-stream")
              |> Plug.Conn.send_chunked(200)

            {:ok, up} = Plug.Conn.chunk(up, hd(@sse))
            up
        end
      end)

      conn = conn |> authed() |> post_json(Map.put(@request, "input", @reasoning_input))
      assert conn.status == 200

      assert_receive {:attempt, 1, first}
      assert Enum.any?(first, &(&1["encrypted_content"] == "gAAAA-stale"))
      assert_receive {:attempt, 2, second}
      refute Enum.any?(second, &Map.has_key?(&1, "encrypted_content"))
    end

    test "any other OpenAI 400 passes through untouched (no retry)", %{conn: conn, bypass: bypass} do
      openai_provider!(bypass)

      Bypass.expect_once(bypass, "POST", "/v1/responses", fn up ->
        up
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, ~s({"error":{"message":"Unsupported parameter: foo"}}))
      end)

      conn = conn |> authed() |> post_json(Map.put(@request, "input", @reasoning_input))
      assert json_response(conn, 400)["error"]["message"] =~ "Unsupported parameter"
    end

    test "a non-OpenAI provider never retries", %{conn: conn, bypass: bypass, provider: provider} do
      configure_default!(provider)

      Bypass.expect_once(bypass, "POST", "/v1/responses", fn up ->
        up
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, ~s({"error":{"message":"encrypted_content is invalid"}}))
      end)

      conn = conn |> authed() |> post_json(Map.put(@request, "input", @reasoning_input))
      assert json_response(conn, 400)["error"]["message"] =~ "encrypted_content"
    end
  end

  describe "configuration problems" do
    test "503 when no default model is configured", %{conn: conn} do
      conn = conn |> authed() |> post_json(@request)
      assert json_response(conn, 503)["error"]["message"] =~ "default model"
    end

    test "503 when the provider has no API key", %{conn: conn} do
      n = System.unique_integer([:positive])

      keyless =
        AI.create_provider!(%{
          name: "Keyless",
          slug: "keyless-#{n}",
          base_url: "http://localhost:1/v1"
        })

      configure_default!(keyless)

      conn = conn |> authed() |> post_json(@request)
      assert json_response(conn, 503)["error"]["message"] =~ "API key"
    end

    test "400 for a body that is not a Responses request", %{conn: conn, provider: provider} do
      configure_default!(provider)
      conn = conn |> authed() |> post_json(%{"messages" => []})
      assert json_response(conn, 400)
    end
  end
end
