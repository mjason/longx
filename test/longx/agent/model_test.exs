defmodule Longx.Agent.ModelTest do
  use Longx.DataCase, async: false

  alias Longx.Agent.Model
  alias Longx.AI
  alias Longx.Test.ResponsesFixture

  setup do
    Ash.bulk_destroy!(AI.Model, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(AI.Provider, :destroy, %{}, authorize?: false)
    Longx.AI.Gateway.Log.clear()

    bypass = Bypass.open()
    n = System.unique_integer([:positive])

    provider =
      AI.create_provider!(%{
        name: "Upstream #{n}",
        slug: "upstream-#{n}",
        base_url: "http://localhost:#{bypass.port}/v1",
        api_key: "sk-upstream"
      })

    model =
      AI.create_model!(%{
        name: "Fake",
        upstream_id: "real-model",
        slug: "fake-#{n}",
        provider_id: provider.id,
        context_window: 64_000
      })

    AI.make_default_model!(model)
    %{bypass: bypass, model: model, provider: provider}
  end

  # the quiet notices' cadence, shortened for one test (restored after it)
  defp quiet_config(after_ms, tick_ms) do
    previous = Application.get_env(:longx, Model, [])

    Application.put_env(
      :longx,
      Model,
      Keyword.merge(previous, quiet_after_ms: after_ms, quiet_tick_ms: tick_ms)
    )

    on_exit(fn -> Application.put_env(:longx, Model, previous) end)
  end

  defp sse(conn, chunks) do
    conn =
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    Enum.reduce(chunks, conn, fn chunk, c ->
      {:ok, c} = Plug.Conn.chunk(c, chunk)
      c
    end)
  end

  defp body!(conn) do
    {:ok, body, _} = Plug.Conn.read_body(conn)
    Jason.decode!(body)
  end

  @request %{
    "model" => "longx",
    "instructions" => "be nice",
    "input" => [%{"type" => "message", "role" => "user", "content" => "hi"}],
    "tools" => [],
    "stream" => true,
    "reasoning" => %{"effort" => "low", "summary" => "auto"}
  }

  test "relays a stream as messages: item added, deltas, item done, completed", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/responses", fn conn ->
      body = body!(conn)
      assert body["model"] == "real-model"
      assert body["stream"] == true
      sse(conn, ResponsesFixture.assistant_message("hello"))
    end)

    ref = make_ref()
    assert :ok = Model.stream(@request, self(), ref)

    assert_receive {:model, ^ref, {:item_added, %{"type" => "message", "id" => id}}}
    assert_receive {:model, ^ref, {:text_delta, ^id, "hello"}}
    assert_receive {:model, ^ref, {:item_done, %{"type" => "message", "id" => ^id}}}

    assert_receive {:model, ^ref,
                    {:completed, %{"usage" => %{"input_tokens" => _}}, %{context_window: 64_000}}}

    assert [%{effort: "low", status: 200, model: "longx", upstream_id: "real-model"}] =
             Longx.AI.Gateway.Log.recent(5)
  end

  test "a content-policy refusal is final whatever the status (a gateway relays OpenAI's as a 502): no retry of the same prompt",
       %{bypass: bypass, model: model} do
    Bypass.expect_once(bypass, "POST", "/v1/responses", fn conn ->
      Plug.Conn.send_resp(
        conn,
        502,
        ~s({"error":{"message":"Invalid prompt: your prompt was flagged as potentially violating our usage policy. Please try again with a different prompt: https://platform.openai.com/docs/guides/reasoning#advice-on-prompting"}})
      )
    end)

    ref = make_ref()
    assert :ok = Model.stream(@request, self(), ref)
    assert_receive {:model, ^ref, {:failed, {:model_failed, slug, message}}}, 2_000
    assert slug == model.slug
    assert message =~ "usage policy"
  end

  test "a quota exhaustion is final at once and names the model; a chain falls back to its next model",
       %{bypass: bypass, model: model} do
    Bypass.expect_once(bypass, "POST", "/v1/responses", fn conn ->
      Plug.Conn.send_resp(
        conn,
        429,
        ~s({"error":{"message":"Your token-plan quota has been exhausted."}})
      )
    end)

    ref = make_ref()
    assert :ok = Model.stream(@request, self(), ref)
    assert_receive {:model, ^ref, {:failed, {:model_failed, slug, message}}}, 2_000
    assert slug == model.slug
    assert message =~ "quota has been exhausted"
    assert message =~ "real-model"
    assert message =~ "upstream-"

    # an alias with two models: the first one's quota is gone, the second serves
    second =
      Longx.AI.create_model!(%{
        name: "Second",
        upstream_id: "real-model-2",
        slug: "second-#{System.unique_integer([:positive])}",
        provider_id: model.provider_id,
        context_window: 32_000
      })

    {:ok, _} = Longx.AI.Aliases.put("ultra", [model.slug, second.slug])

    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      case body!(conn)["model"] do
        "real-model" ->
          Plug.Conn.send_resp(conn, 429, ~s({"error":{"message":"quota exhausted"}}))

        "real-model-2" ->
          sse(conn, ResponsesFixture.assistant_message("second serves"))
      end
    end)

    ref2 = make_ref()
    assert :ok = Model.stream(%{@request | "model" => "ultra"}, self(), ref2)
    # the fallback names the models as the person knows them: by slug
    assert_receive {:model, ^ref2, {:fallback, from, to, reason}}, 5_000
    assert {from, to} == {model.slug, second.slug}
    assert reason =~ "quota"
    assert_receive {:model, ^ref2, {:completed, _, %{context_window: 32_000}}}, 5_000
  end

  test "a 5xx or a 429 is retried; a 4xx is final", %{bypass: bypass} do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      n = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})

      case n do
        1 -> Plug.Conn.send_resp(conn, 503, ~s({"error":{"message":"overloaded"}}))
        2 -> Plug.Conn.send_resp(conn, 429, "slow down")
        _ -> sse(conn, ResponsesFixture.assistant_message("ok"))
      end
    end)

    ref = make_ref()
    assert :ok = Model.stream(@request, self(), ref)
    assert_receive {:model, ^ref, {:completed, _, _}}, 5_000
    assert Agent.get(counter, & &1) == 3

    Bypass.expect_once(bypass, "POST", "/v1/responses", fn conn ->
      Plug.Conn.send_resp(conn, 400, ~s({"error":{"message":"bad request here"}}))
    end)

    ref2 = make_ref()
    assert :ok = Model.stream(@request, self(), ref2)
    assert_receive {:model, ^ref2, {:failed, {:model_failed, _slug, message}}}
    assert message =~ "bad request here"
    assert message =~ "400"
  end

  test "a grammar tool goes out as a custom tool to OpenAI and as a function elsewhere", %{
    bypass: bypass,
    model: model
  } do
    custom = %{
      "type" => "custom",
      "name" => "apply_patch",
      "description" => "d",
      "format" => %{"type" => "grammar", "syntax" => "lark", "definition" => "start: x"}
    }

    function = %{
      "type" => "function",
      "name" => "apply_patch",
      "description" => "d",
      "parameters" => %{"type" => "object"}
    }

    request = Map.merge(@request, %{"tools" => [function], "x-longx-custom-tools" => [custom]})

    Bypass.expect_once(bypass, "POST", "/v1/responses", fn conn ->
      body = body!(conn)
      assert [%{"type" => "function"}] = body["tools"]
      refute Map.has_key?(body, "x-longx-custom-tools")
      sse(conn, ResponsesFixture.assistant_message("ok"))
    end)

    assert :ok = Model.stream(request, self(), make_ref())

    provider = Ash.load!(model, :provider).provider
    AI.update_provider!(provider, %{kind: :openai})

    Bypass.expect_once(bypass, "POST", "/v1/responses", fn conn ->
      body = body!(conn)

      assert [%{"type" => "custom", "name" => "apply_patch", "format" => %{"syntax" => "lark"}}] =
               body["tools"]

      refute Map.has_key?(body, "x-longx-custom-tools")
      sse(conn, ResponsesFixture.assistant_message("ok"))
    end)

    assert :ok = Model.stream(request, self(), make_ref())
  end

  test "an unknown model fails without a request" do
    ref = make_ref()
    assert :ok = Model.stream(%{@request | "model" => "nope"}, self(), ref)
    assert_receive {:model, ^ref, {:failed, message}}
    assert message =~ "nope"
  end

  test "a provider's own failure event that says to retry (a server error, an overload) is retried like a 5xx; one that does not is final",
       %{bypass: bypass, model: model} do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    transient =
      ~s(event: error\ndata: {"type":"error","error":{"type":"server_error","message":"An error occurred while processing your request. You can retry your request, or contact us through our help center."}}\n\n)

    [created | _] = ResponsesFixture.assistant_message("x")

    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      n = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})

      if n == 1,
        do: sse(conn, [created, transient]),
        else: sse(conn, ResponsesFixture.assistant_message("fine now"))
    end)

    ref = make_ref()
    assert :ok = Model.stream(@request, self(), ref)
    assert_receive {:model, ^ref, {:restart, why}}, 5_000
    assert why =~ "retry"
    assert_receive {:model, ^ref, {:completed, _, _}}, 5_000
    assert Agent.get(counter, & &1) == 2

    final =
      ~s(event: error\ndata: {"type":"error","error":{"type":"invalid_request_error","message":"Unsupported parameter: reasoning"}}\n\n)

    Bypass.expect(bypass, "POST", "/v1/responses", fn conn -> sse(conn, [created, final]) end)
    ref2 = make_ref()
    assert :ok = Model.stream(@request, self(), ref2)
    assert_receive {:model, ^ref2, {:failed, {:model_failed, slug, message}}}, 5_000
    assert slug == model.slug
    assert message =~ "Unsupported parameter"
    refute_received {:model, ^ref2, {:restart, _}}
  end

  # the ChatGPT backend once stopped mid-call (300 bytes of an apply_patch) and
  # kept the connection open: the silence limit was the request timeout, ten
  # minutes, and the retry then took a pooled connection the server had closed
  # meanwhile ("socket closed", 15 s more)
  test "a stream silent past the provider's stream idle timeout — not its request timeout — is retried: the stuck response is cancelled, the owner told how long it was quiet",
       %{bypass: bypass, provider: provider} do
    AI.update_provider!(provider, %{stream_idle_timeout_ms: 400})
    assert provider |> Ash.reload!() |> Map.get(:request_timeout_ms) == 600_000
    quiet_config(100, 50)
    me = self()
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    [created, added, delta | _] = ResponsesFixture.assistant_message("hello there")

    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      if Agent.get_and_update(counter, &{&1 + 1, &1 + 1}) == 1 do
        # a few events, then nothing — the connection held open
        conn = sse(conn, [created, added, delta])
        send(me, {:stuck, self()})

        receive do
          :never -> conn
        end
      else
        sse(conn, ResponsesFixture.assistant_message("hello there"))
      end
    end)

    ref = make_ref()
    task = Task.async(fn -> Model.stream(@request, me, ref) end)
    assert_receive {:stuck, handler}, 5_000
    watch = Process.monitor(handler)
    # quiet past 100 ms: said, and said again while it lasts
    assert_receive {:model, ^ref, {:quiet, ms}}, 2_000
    assert ms >= 100
    assert_receive {:model, ^ref, {:quiet, later}}, 2_000
    assert later > ms
    assert_receive {:model, ^ref, {:restart, why}}, 2_000
    assert why =~ "silent for 400 ms"
    # the stuck response is cancelled: its connection closes, the server's handler goes
    assert_receive {:DOWN, ^watch, :process, ^handler, _}, 2_000
    assert_receive {:model, ^ref, {:completed, _, _}}, 5_000
    assert :ok = Task.await(task, 5_000)
    Bypass.pass(bypass)
  end

  test "a pause shorter than the idle timeout is said when it passes the quiet threshold and unsaid when the stream resumes",
       %{bypass: bypass, provider: provider} do
    AI.update_provider!(provider, %{stream_idle_timeout_ms: 5_000})
    quiet_config(100, 50)
    [created, added, delta | rest] = ResponsesFixture.assistant_message("hello there")

    Bypass.expect_once(bypass, "POST", "/v1/responses", fn conn ->
      conn = sse(conn, [created, added, delta])
      Process.sleep(300)
      Enum.reduce(rest, conn, fn chunk, c -> elem(Plug.Conn.chunk(c, chunk), 1) end)
    end)

    ref = make_ref()
    assert :ok = Model.stream(@request, self(), ref)
    assert_received {:model, ^ref, {:quiet, ms}} when ms >= 100
    assert_received {:model, ^ref, {:quiet, nil}}
    assert_received {:model, ^ref, {:completed, _, _}}
    refute_received {:model, ^ref, {:restart, _}}
  end

  # an upstream (or a proxy on the way) may drop a keep-alive connection without
  # the close reaching us: reused after ten idle minutes it answered "socket
  # closed" — the model requests' pool opens a fresh one past `conn_max_idle_time`
  # (30 s; config/test.exs: 200 ms)
  test "a pooled connection idle past the limit is not reused: the next request opens a fresh one",
       %{bypass: bypass} do
    me = self()

    Bypass.stub(bypass, "POST", "/v1/responses", fn conn ->
      send(me, {:peer, Plug.Conn.get_peer_data(conn).port})
      sse(conn, ResponsesFixture.assistant_message("hi"))
    end)

    run = fn ->
      ref = make_ref()
      assert :ok = Model.stream(@request, me, ref)
      assert_received {:model, ^ref, {:completed, _, _}}
      assert_receive {:peer, port}, 1_000
      port
    end

    first = run.()

    receive do
    after
      400 -> :ok
    end

    refute run.() == first
  end

  test "a stream that breaks mid-way is retried on the same model — the owner told to start over — and completes; past the retries the failure is final and structured",
       %{bypass: bypass, model: model} do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    [created, added, delta | _] = ResponsesFixture.assistant_message("hello there")

    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      n = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      # twice: a few events, then the connection drops
      if n <= 2,
        do: sse(conn, [created, added, delta]),
        else: sse(conn, ResponsesFixture.assistant_message("hello there"))
    end)

    ref = make_ref()
    assert :ok = Model.stream(@request, self(), ref)
    # the partial output reached the owner, then the word to drop it and wait
    assert_receive {:model, ^ref, {:text_delta, _, _}}, 5_000
    assert_receive {:model, ^ref, {:restart, why}}, 5_000
    assert why =~ "ended"
    assert_receive {:model, ^ref, {:restart, _}}, 5_000
    assert_receive {:model, ^ref, {:completed, _, _}}, 5_000
    assert Agent.get(counter, & &1) == 3

    # every attempt breaks: the failure names the model and is final
    Agent.update(counter, fn _ -> 0 end)
    Bypass.expect(bypass, "POST", "/v1/responses", fn conn -> sse(conn, [created]) end)
    ref2 = make_ref()
    assert :ok = Model.stream(@request, self(), ref2)
    assert_receive {:model, ^ref2, {:failed, {:model_failed, slug, message}}}, 10_000
    assert slug == model.slug
    assert message =~ "ended"
  end
end
