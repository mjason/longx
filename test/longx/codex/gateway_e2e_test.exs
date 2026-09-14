defmodule Longx.Codex.GatewayE2ETest do
  @moduledoc """
  The whole chain through the real client: bundled codex-app-server ⇄
  Longx.Codex.Connection, and codex → our /ai/v1/* → a Bypass upstream.
  Excluded by default: `mix test --include integration`.
  """
  use Longx.DataCase, async: false

  import Longx.Test.CodexHarness

  alias Longx.AI
  alias Longx.Codex.Thread
  alias Longx.Test.ResponsesFixture

  @moduletag :integration
  @moduletag timeout: 120_000

  setup do
    Ash.bulk_destroy!(AI.Model, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(AI.Provider, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(AI.SearchProvider, :destroy, %{}, authorize?: false)
    %{gateway_url: serve_endpoint!()}
  end

  defp send_sse(conn, frames) do
    conn =
      conn |> Plug.Conn.put_resp_content_type("text/event-stream") |> Plug.Conn.send_chunked(200)

    Enum.reduce(frames, conn, fn frame, conn ->
      {:ok, conn} = Plug.Conn.chunk(conn, frame)
      conn
    end)
  end

  defp fake_provider!(bypass, attrs \\ %{}) do
    provider =
      AI.create_provider!(
        Map.merge(
          %{
            name: "Fake",
            slug: "fake-#{System.unique_integer([:positive])}",
            base_url: "http://localhost:#{bypass.port}/v1",
            api_key: "sk-fake"
          },
          attrs
        )
      )

    AI.create_model!(%{name: "Fake", upstream_id: "fake-model", provider_id: provider.id})
    |> AI.make_default_model!()

    provider
  end

  test "a turn completes through the gateway with the configured upstream model", %{
    gateway_url: gateway_url
  } do
    bypass = Bypass.open()
    fake_provider!(bypass)
    test_pid = self()

    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn, length: 50_000_000)
      send(test_pid, {:upstream_request, conn.req_headers, Jason.decode!(raw)})
      send_sse(conn, ResponsesFixture.assistant_message("Hello from the fake upstream."))
    end)

    home = prepare_home!(gateway_url)
    conn = start_connection!(home)
    thread_id = start_thread!(conn, home)

    {turn, items} = run_turn!(conn, thread_id, "hi")
    assert turn["status"] == "completed", inspect(turn)
    assert agent_messages(items) == ["Hello from the fake upstream."]

    # the projection agrees with the stream
    snapshot = Thread.snapshot(thread_id)
    assert snapshot.turn["status"] == "completed"

    assert Enum.any?(
             snapshot.items,
             &(&1["type"] == "agentMessage" and &1["text"] == "Hello from the fake upstream.")
           )

    assert_receive {:upstream_request, headers, body}, 5_000
    assert {"authorization", "Bearer sk-fake"} in headers
    refute List.keymember?(headers, "thread-id", 0)
    assert body["model"] == "fake-model"
    assert body["client_metadata"] == nil
    assert body["stream"] == true
    assert Enum.any?(body["tools"], &(&1["type"] == "namespace"))
  end

  test "web.run goes through our /alpha/search and back into the turn", %{
    gateway_url: gateway_url
  } do
    upstream = Bypass.open()
    tavily = Bypass.open()
    test_pid = self()
    fake_provider!(upstream)

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

    # web_search mode is resolved from the DB: a search provider exists → :standalone
    assert AI.web_search_mode() == :standalone
    home = prepare_home!(gateway_url)
    conn = start_connection!(home)
    thread_id = start_thread!(conn, home)

    {turn, items} = run_turn!(conn, thread_id, "what's new in elixir 1.19?")
    assert turn["status"] == "completed", inspect(turn)

    assert_receive {:upstream_request, 1, first}, 5_000
    assert Enum.any?(first["tools"], &(&1["type"] == "namespace" and &1["name"] == "web"))
    refute Enum.any?(first["tools"], &(&1["type"] == "web_search"))

    assert_receive {:tavily_request, %{"query" => "elixir 1.19 release"}}, 5_000

    assert_receive {:upstream_request, 2, second}, 5_000

    assert Enum.any?(
             second["input"],
             &(&1["type"] == "function_call_output" and
                 inspect(&1["output"]) =~ "elixir-lang.org/blog/1.19")
           )

    assert Enum.any?(items, &(&1["type"] == "webSearch" and &1["query"] =~ "elixir 1.19"))
  end

  test "an Elixir tool (dynamicTools) is offered to the model and executed via item/tool/call", %{
    gateway_url: gateway_url
  } do
    upstream = Bypass.open()
    test_pid = self()
    fake_provider!(upstream)
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
            ResponsesFixture.function_call("echo", "builtin", %{message: "round trip"})
          )

        _ ->
          send_sse(conn, ResponsesFixture.assistant_message("The tool said: round trip"))
      end
    end)

    home = prepare_home!(gateway_url)
    conn = start_connection!(home)
    thread_id = start_thread!(conn, home, tools: ["builtin.echo"])

    {turn, items} = run_turn!(conn, thread_id, "use the echo tool")
    assert turn["status"] == "completed", inspect(turn)

    # codex advertised our tools to the model as a namespace…
    assert_receive {:upstream_request, 1, first}, 5_000
    builtin = Enum.find(first["tools"], &(&1["type"] == "namespace" and &1["name"] == "builtin"))

    assert builtin,
           "builtin namespace not offered: #{inspect(Enum.map(first["tools"], &{&1["type"], &1["name"]}))}"

    assert Enum.any?(builtin["tools"], &(&1["name"] == "echo"))

    # …executed it through us, and fed the output back into the next model call
    assert_receive {:upstream_request, 2, second}, 5_000

    assert Enum.any?(
             second["input"],
             &(&1["type"] == "function_call_output" and inspect(&1["output"]) =~ "round trip")
           )

    # and reported it as a dynamicToolCall item
    assert Enum.any?(items, &(&1["type"] == "dynamicToolCall" and &1["tool"] == "echo"))
    assert Enum.any?(Thread.snapshot(thread_id).items, &(&1["type"] == "dynamicToolCall"))
  end

  test "codex's own memory tools are offered; add_ad_hoc_note writes into the home's memories", %{
    gateway_url: gateway_url
  } do
    upstream = Bypass.open()
    test_pid = self()
    fake_provider!(upstream)
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
            ResponsesFixture.function_call("add_ad_hoc_note", "memories", %{
              filename: "2026-09-14T12-00-00-prefers-tabs.md",
              note: "The user prefers tabs over spaces."
            })
          )

        _ ->
          send_sse(conn, ResponsesFixture.assistant_message("Noted."))
      end
    end)

    home = prepare_home!(gateway_url)
    conn = start_connection!(home)
    thread_id = start_thread!(conn, home, tools: [])

    {turn, items} = run_turn!(conn, thread_id, "remember that I prefer tabs")
    assert turn["status"] == "completed", inspect(turn)

    # the memories namespace, with its four tools, reaches the model through us
    assert_receive {:upstream_request, 1, first}, 5_000
    memories = Enum.find(first["tools"], &(&1["type"] == "namespace" and &1["name"] == "memories"))

    assert memories,
           "memories namespace not offered: #{inspect(Enum.map(first["tools"], &{&1["type"], &1["name"]}))}"

    assert Enum.map(memories["tools"], & &1["name"]) |> Enum.sort() ==
             ["add_ad_hoc_note", "list", "read", "search"]

    # codex ran it inside itself: the note is on disk, the output went back to the model
    assert_receive {:upstream_request, 2, second}, 5_000
    assert Enum.any?(second["input"], &(&1["type"] == "function_call_output"))

    notes = Path.wildcard(Path.join(home.dir, "memories/extensions/ad_hoc/notes/*.md"))
    assert [note] = notes
    assert File.read!(note) == "The user prefers tabs over spaces."

    # codex 0.154 reports nothing for the call on the wire (only the messages):
    # the UI cannot show it — this assertion is here to notice when that changes
    assert Enum.map(items, & &1["type"]) == ["userMessage", "agentMessage"]
  end

  test "web_search: :hosted hands the upstream its own web_search tool and nothing of ours", %{
    gateway_url: gateway_url
  } do
    upstream = Bypass.open()
    test_pid = self()
    fake_provider!(upstream, %{supports_hosted_web_search: true})

    Bypass.expect(upstream, "POST", "/v1/responses", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn, length: 50_000_000)
      send(test_pid, {:upstream_request, Jason.decode!(raw)})

      send_sse(
        conn,
        ResponsesFixture.assistant_message("Hosted search would have happened upstream.")
      )
    end)

    assert AI.web_search_mode() == :hosted
    home = prepare_home!(gateway_url)
    conn = start_connection!(home)
    thread_id = start_thread!(conn, home)

    {turn, _items} = run_turn!(conn, thread_id, "hi")
    assert turn["status"] == "completed", inspect(turn)

    assert_receive {:upstream_request, body}, 5_000

    assert Enum.any?(
             body["tools"],
             &match?(%{"type" => "web_search", "external_web_access" => true}, &1)
           )

    refute Enum.any?(body["tools"], &(&1["type"] == "namespace" and &1["name"] == "web"))
  end

  test "per-thread overrides win over the global config: search mode and reasoning settings", %{
    gateway_url: gateway_url
  } do
    upstream = Bypass.open()
    test_pid = self()
    fake_provider!(upstream, %{supports_hosted_web_search: true})
    {:ok, model} = AI.default_model()
    AI.update_model!(model, %{max_output_tokens: 4_096})

    Bypass.expect(upstream, "POST", "/v1/responses", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn, length: 50_000_000)
      send(test_pid, {:upstream_request, Jason.decode!(raw)})
      send_sse(conn, ResponsesFixture.assistant_message("ok"))
    end)

    # codex boots with search disabled globally…
    home = prepare_home!(gateway_url, web_search: :disabled)
    conn = start_connection!(home)

    # …but this thread asks for standalone search and a specific reasoning setup
    standalone =
      start_thread!(conn, home,
        web_search: :standalone,
        reasoning_effort: "high",
        reasoning_summary: :detailed
      )

    {turn, _} = run_turn!(conn, standalone, "hi")
    assert turn["status"] == "completed", inspect(turn)
    assert_receive {:upstream_request, body}, 5_000
    assert Enum.any?(body["tools"], &(&1["type"] == "namespace" and &1["name"] == "web"))
    refute Enum.any?(body["tools"], &(&1["type"] == "web_search"))
    assert body["reasoning"] == %{"effort" => "high", "summary" => "detailed"}
    # the model's cap, added by the gateway
    assert body["max_output_tokens"] == 4_096

    # and another thread on the same connection gets hosted search
    hosted = start_thread!(conn, home, web_search: :hosted)
    {turn, _} = run_turn!(conn, hosted, "hi")
    assert turn["status"] == "completed", inspect(turn)
    assert_receive {:upstream_request, body}, 5_000
    assert Enum.any?(body["tools"], &(&1["type"] == "web_search"))
    refute Enum.any?(body["tools"], &(&1["type"] == "namespace" and &1["name"] == "web"))
    # codex's own reasoning defaults for a thread that set none
    refute body["reasoning"]["effort"] == "high"
  end

  test "the model's context window reaches codex at start and again at resume (95% usable is what it reports)",
       %{gateway_url: gateway_url} do
    upstream = Bypass.open()
    fake_provider!(upstream)

    Bypass.expect(upstream, "POST", "/v1/responses", fn conn ->
      {:ok, _raw, conn} = Plug.Conn.read_body(conn, length: 50_000_000)
      send_sse(conn, ResponsesFixture.assistant_message("ok"))
    end)

    # the catalog codex boots with says this model takes 1M (its own fallback
    # would cap any override at 272k); the row's window of the day is the
    # per-thread override
    {:ok, model} = AI.default_model()
    AI.update_model!(model, %{context_window: 1_000_000})
    home = prepare_home!(gateway_url)
    conn = start_connection!(home)
    thread_id = start_thread!(conn, home, model_context_window: 128_000)
    {turn, _} = run_turn!(conn, thread_id, "hi")
    assert turn["status"] == "completed", inspect(turn)
    assert window(thread_id) == 121_600

    # the row was edited to 1M; codex restarted (a new process on the same
    # home) — the resume carries the new window
    :ok = stop_supervised({:conn, home.dir})
    Longx.Codex.ThreadState.stop(thread_id)
    conn = start_connection!(home, :conn2)

    assert {:ok, ^thread_id} =
             Thread.resume(thread_id, conn: conn, model_context_window: 1_000_000)

    {turn, _} = run_turn!(conn, thread_id, "hi again")
    assert turn["status"] == "completed", inspect(turn)
    assert window(thread_id) == 950_000
  end

  test "the vendored base instructions are what the bundled binary embeds (refresh priv/codex_prompt.md on a codex bump)" do
    {:ok, exe} = Longx.Codex.Runtime.executable()
    assert :binary.match(File.read!(exe), Longx.Codex.Home.base_instructions()) != :nomatch
  end

  defp window(thread_id) do
    get_in(Thread.snapshot(thread_id).token_usage, ["modelContextWindow"])
  end

  test "multi_agent: the thread gets codex's sub-agent tools (spawn / wait / …)", %{
    gateway_url: gateway_url
  } do
    upstream = Bypass.open()
    test_pid = self()
    fake_provider!(upstream)

    Bypass.expect(upstream, "POST", "/v1/responses", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn, length: 50_000_000)
      send(test_pid, {:upstream_request, Jason.decode!(raw)})
      send_sse(conn, ResponsesFixture.assistant_message("ok"))
    end)

    home = prepare_home!(gateway_url)
    conn = start_connection!(home)

    plain = start_thread!(conn, home)
    {turn, _} = run_turn!(conn, plain, "hi")
    assert turn["status"] == "completed", inspect(turn)
    assert_receive {:upstream_request, without}, 5_000

    agents = start_thread!(conn, home, multi_agent: true)
    {turn, _} = run_turn!(conn, agents, "hi")
    assert turn["status"] == "completed", inspect(turn)
    assert_receive {:upstream_request, with_agents}, 5_000

    names = fn body ->
      body["tools"]
      |> Enum.flat_map(fn
        %{"type" => "namespace", "name" => ns, "tools" => tools} ->
          Enum.map(tools, &"#{ns}.#{&1["name"]}")

        %{"name" => name} ->
          [name]

        _ ->
          []
      end)
    end

    # 0.154 offers its v1 sub-agent tools by default; ours asks for v2 (the
    # `collaboration` namespace: spawn / wait / send_message / followup / interrupt / list)
    assert "multi_agent_v1.spawn_agent" in names.(without)
    assert "collaboration.spawn_agent" in names.(with_agents)
    assert "collaboration.wait_agent" in names.(with_agents)
    refute "multi_agent_v1.spawn_agent" in names.(with_agents)

    # and off means no sub-agent tools at all
    solo = start_thread!(conn, home, multi_agent: false)
    {turn, _} = run_turn!(conn, solo, "hi")
    assert turn["status"] == "completed", inspect(turn)
    assert_receive {:upstream_request, alone}, 5_000
    refute Enum.any?(names.(alone), &String.contains?(&1, "spawn")), inspect(names.(alone))
  end
end
