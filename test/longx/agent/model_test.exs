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
    %{bypass: bypass, model: model}
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
    assert_receive {:model, ^ref2, {:failed, message}}
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

  test "a stream that ends without a completion is a failure", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/responses", fn conn ->
      sse(conn, ["event: response.created\ndata: {\"type\":\"response.created\"}\n\n"])
    end)

    ref = make_ref()
    assert :ok = Model.stream(@request, self(), ref)
    assert_receive {:model, ^ref, {:failed, message}}
    assert message =~ "ended"
  end
end
