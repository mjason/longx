defmodule Longx.AI.GatewayTest do
  use ExUnit.Case, async: true

  alias Longx.AI.{Gateway, Target}

  @target %Target{
    model: "deepseek-v4-pro",
    base_url: "https://api.deepseek.com/v1",
    api_key: "sk-ds",
    context_window: 128_000,
    provider_slug: "deepseek"
  }

  # A trimmed copy of what codex 0.154 actually sends
  @codex_body %{
    "model" => "longx",
    "instructions" => "You are Codex...",
    "input" => [
      %{
        "type" => "message",
        "role" => "user",
        "content" => [%{"type" => "input_text", "text" => "hi"}]
      }
    ],
    "tools" => [
      %{"type" => "function", "name" => "exec_command", "parameters" => %{}},
      %{
        "type" => "namespace",
        "name" => "web",
        "tools" => [%{"type" => "function", "name" => "run"}]
      }
    ],
    "tool_choice" => "auto",
    "parallel_tool_calls" => true,
    "reasoning" => %{"summary" => "auto"},
    "store" => false,
    "stream" => true,
    "include" => ["reasoning.encrypted_content"],
    "prompt_cache_key" => "thread-1",
    "client_metadata" => %{"thread_id" => "thread-1"}
  }

  describe "prepare/2" do
    test "targets <base_url>/responses with the provider's credentials" do
      {:ok, up} = Gateway.prepare(@codex_body, @target)

      assert up.url == "https://api.deepseek.com/v1/responses"
      assert {"authorization", "Bearer sk-ds"} in up.headers
      assert {"accept", "text/event-stream"} in up.headers
    end

    test "handles a base_url with a trailing slash" do
      {:ok, up} =
        Gateway.prepare(@codex_body, %Target{@target | base_url: "https://x.example/v1/"})

      assert up.url == "https://x.example/v1/responses"
    end

    test "swaps the placeholder model for the upstream id and keeps the rest" do
      {:ok, up} = Gateway.prepare(@codex_body, @target)

      assert up.body["model"] == "deepseek-v4-pro"
      assert up.body["stream"] == true
      assert up.body["instructions"] == "You are Codex..."
      assert up.body["input"] == @codex_body["input"]
      assert up.body["reasoning"] == %{"summary" => "auto"}
    end

    test "passes every tool through untouched — codex decides what to offer via config" do
      {:ok, up} = Gateway.prepare(@codex_body, @target)
      assert up.body["tools"] == @codex_body["tools"]
    end

    test "drops codex-internal fields that are not part of the public API" do
      {:ok, up} = Gateway.prepare(@codex_body, @target)
      refute Map.has_key?(up.body, "client_metadata")
    end

    test "forces streaming — the relay is SSE only" do
      {:ok, up} = Gateway.prepare(Map.put(@codex_body, "stream", false), @target)
      assert up.body["stream"] == true
    end

    test "rejects a body that is not a Responses request" do
      assert {:error, :invalid_request} = Gateway.prepare(%{"messages" => []}, @target)
      assert {:error, :invalid_request} = Gateway.prepare("nope", @target)
    end
  end
end
