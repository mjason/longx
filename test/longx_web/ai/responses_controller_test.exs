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
