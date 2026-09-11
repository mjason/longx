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
    Ash.bulk_destroy!(AI.SearchProvider, :destroy, %{}, authorize?: false)

    # Serve the real endpoint on a loopback port for codex to call.
    {:ok, bandit} =
      start_supervised(
        {Bandit, plug: LongxWeb.Endpoint, scheme: :http, ip: {127, 0, 0, 1}, port: 0}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)

    home_dir =
      Path.join(Path.expand("data"), "codex_home_e2e_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(home_dir) end)
    gateway_url = "http://127.0.0.1:#{port}/ai/v1"
    {:ok, home} = Home.prepare(dir: home_dir, gateway_url: gateway_url)

    %{home: home, home_dir: home_dir, gateway_url: gateway_url}
  end

  defp send_sse(conn, frames) do
    conn =
      conn |> Plug.Conn.put_resp_content_type("text/event-stream") |> Plug.Conn.send_chunked(200)

    Enum.reduce(frames, conn, fn frame, conn ->
      {:ok, conn} = Plug.Conn.chunk(conn, frame)
      conn
    end)
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
    # nothing is filtered: namespace tools (sub-agents, web.run) reach the upstream as-is
    assert Enum.any?(body["tools"], &(&1["type"] == "namespace"))

    CodexClient.stop(shim)
  end

  test "web.run goes through our /alpha/search and back into the turn", %{
    home_dir: home_dir,
    gateway_url: gateway_url
  } do
    # standalone web search on: codex offers `web.run` and calls our endpoint
    {:ok, home} = Home.prepare(dir: home_dir, gateway_url: gateway_url, web_search: :standalone)

    upstream = Bypass.open()
    tavily = Bypass.open()
    test_pid = self()

    provider =
      AI.create_provider!(%{
        name: "Fake",
        slug: "fake-#{System.unique_integer([:positive])}",
        base_url: "http://localhost:#{upstream.port}/v1",
        api_key: "sk-fake"
      })

    AI.create_model!(%{name: "Fake", upstream_id: "fake-model", provider_id: provider.id})
    |> AI.make_default_model!()

    AI.create_search_provider!(%{
      name: "Fake Tavily",
      slug: "tavily-#{System.unique_integer([:positive])}",
      kind: :tavily,
      base_url: "http://localhost:#{tavily.port}",
      api_key: "tvly-fake"
    })
    |> AI.make_default_search_provider!()

    Bypass.expect_once(tavily, "POST", "/search", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:tavily_request, Jason.decode!(raw)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "results" => [
            %{
              "title" => "Elixir 1.19 released",
              "url" => "https://elixir-lang.org/blog/1.19",
              "content" => "Elixir 1.19 is out."
            }
          ]
        })
      )
    end)

    # 1st model call: ask for a web search; 2nd: answer using the tool output
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    Bypass.expect(upstream, "POST", "/v1/responses", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn, length: 50_000_000)
      body = Jason.decode!(raw)
      n = Agent.get_and_update(calls, &{&1 + 1, &1 + 1})
      send(test_pid, {:upstream_request, n, body})

      case n do
        1 ->
          send_sse(
            conn,
            ResponsesFixture.function_call("run", "web", %{
              search_query: [%{q: "elixir 1.19 release"}]
            })
          )

        _ ->
          send_sse(
            conn,
            ResponsesFixture.assistant_message(
              "Elixir 1.19 is out — https://elixir-lang.org/blog/1.19"
            )
          )
      end
    end)

    {shim, thread_id} = CodexClient.start_thread(home)
    turn = CodexClient.run_turn(shim, thread_id, "what's new in elixir 1.19?")

    assert turn["status"] == "completed", "turn did not complete: #{inspect(turn)}"

    # codex offered web.run as a namespace tool and the upstream saw it
    assert_receive {:upstream_request, 1, first}, 5_000
    assert Enum.any?(first["tools"], &(&1["type"] == "namespace" and &1["name"] == "web"))
    refute Enum.any?(first["tools"], &(&1["type"] == "web_search"))

    # our search endpoint ran the query against "Tavily"
    assert_receive {:tavily_request, %{"query" => "elixir 1.19 release"}}, 5_000

    # and the tool output made it back into the second model call
    assert_receive {:upstream_request, 2, second}, 5_000

    assert Enum.any?(second["input"], fn item ->
             item["type"] == "function_call_output" and
               inspect(item["output"]) =~ "elixir-lang.org/blog/1.19"
           end)

    # codex surfaced it as a webSearch item
    assert_received {:item_completed, "webSearch", %{"query" => query}}
    assert query =~ "elixir 1.19"

    CodexClient.stop(shim)
  end

  test "web_search: :hosted hands the upstream its own web_search tool and nothing of ours", %{
    home_dir: home_dir,
    gateway_url: gateway_url
  } do
    {:ok, home} = Home.prepare(dir: home_dir, gateway_url: gateway_url, web_search: :hosted)

    upstream = Bypass.open()
    test_pid = self()

    provider =
      AI.create_provider!(%{
        name: "Fake OpenAI",
        slug: "openai-#{System.unique_integer([:positive])}",
        base_url: "http://localhost:#{upstream.port}/v1",
        api_key: "sk-fake",
        supports_hosted_web_search: true
      })

    AI.create_model!(%{name: "Fake", upstream_id: "fake-model", provider_id: provider.id})
    |> AI.make_default_model!()

    Bypass.expect(upstream, "POST", "/v1/responses", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn, length: 50_000_000)
      send(test_pid, {:upstream_request, Jason.decode!(raw)})

      send_sse(
        conn,
        ResponsesFixture.assistant_message("Hosted search would have happened upstream.")
      )
    end)

    {shim, thread_id} = CodexClient.start_thread(home)
    turn = CodexClient.run_turn(shim, thread_id, "hi")
    assert turn["status"] == "completed", "turn did not complete: #{inspect(turn)}"

    assert_receive {:upstream_request, body}, 5_000

    assert Enum.any?(
             body["tools"],
             &match?(%{"type" => "web_search", "external_web_access" => true}, &1)
           )

    refute Enum.any?(body["tools"], &(&1["type"] == "namespace" and &1["name"] == "web"))

    CodexClient.stop(shim)
  end
end
