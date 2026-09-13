defmodule Longx.AI.GatewayTest do
  use ExUnit.Case, async: true

  alias Longx.AI.{Gateway, Target}

  @target %Target{
    model: "deepseek-v4-pro",
    base_url: "https://api.deepseek.com/v1",
    api_key: "sk-ds",
    context_window: 128_000,
    provider_slug: "deepseek",
    kind: :openai_compatible
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

  describe "prepare/2 reasoning sanitation — a provider only ever gets its own opaque reasoning" do
    @openai_item %{
      "type" => "reasoning",
      "id" => "rs_abc",
      "summary" => [%{"type" => "summary_text", "text" => "s"}],
      "encrypted_content" => "gAAAA-openai"
    }
    @deepseek_item %{
      "type" => "reasoning",
      "id" => "9c542237-49df-4e72-959e-f854ecb90a13",
      "content" => [%{"type" => "reasoning_text", "text" => "thinking"}],
      "summary" => [],
      "encrypted_content" => "9c542237-49df-4e72-959e-f854ecb90a13-0"
    }
    @bare_foreign_item %{
      "type" => "reasoning",
      "id" => "9c542237-0000-0000-0000-000000000000",
      "summary" => [],
      "encrypted_content" => "opaque"
    }
    @message %{
      "type" => "message",
      "role" => "user",
      "content" => [%{"type" => "input_text", "text" => "hi"}]
    }

    defp with_input(items), do: Map.put(@codex_body, "input", items)
    defp openai, do: %Target{@target | kind: :openai, provider_slug: "openai"}

    test "OpenAI target: its own rs_ items pass verbatim, other providers' encrypted_content is stripped" do
      {:ok, up} = Gateway.prepare(with_input([@message, @openai_item, @deepseek_item]), openai())

      assert [@message, @openai_item, deepseek] = up.body["input"]
      refute Map.has_key?(deepseek, "encrypted_content")
      assert deepseek["content"] == @deepseek_item["content"]
    end

    test "non-OpenAI target: every encrypted_content is stripped, including OpenAI's" do
      {:ok, up} = Gateway.prepare(with_input([@openai_item, @deepseek_item]), @target)
      assert Enum.all?(up.body["input"], &(not Map.has_key?(&1, "encrypted_content")))
      # readable reasoning stays
      assert Enum.any?(up.body["input"], &(&1["id"] == "rs_abc" and &1["summary"] != []))
    end

    test "a reasoning item left with nothing readable is dropped entirely" do
      {:ok, up} = Gateway.prepare(with_input([@message, @bare_foreign_item, @message]), openai())
      assert up.body["input"] == [@message, @message]
    end

    test "a user message with an image (the composer's attachment) reaches every provider as sent" do
      with_image = %{
        "type" => "message",
        "role" => "user",
        "content" => [
          %{"type" => "input_text", "text" => "what colour"},
          %{
            "type" => "input_image",
            "image_url" => "data:image/png;base64,AAAA",
            "detail" => "auto"
          }
        ]
      }

      {:ok, up} = Gateway.prepare(with_input([with_image]), @target)
      assert up.body["input"] == [with_image]
      {:ok, up} = Gateway.prepare(with_input([with_image]), openai())
      assert up.body["input"] == [with_image]
    end

    test "non-reasoning items are never touched" do
      call = %{
        "type" => "function_call",
        "id" => "fc_1",
        "call_id" => "c",
        "name" => "f",
        "arguments" => "{}"
      }

      {:ok, up} = Gateway.prepare(with_input([@message, call]), openai())
      assert up.body["input"] == [@message, call]
    end

    test "sub-agent envelopes (agent_message with an `encrypted_content` payload) reach a non-OpenAI model as a plain user message" do
      # what codex puts in front of a spawned sub-agent: the task text travels
      # as an `encrypted_content` part — readable, but ignored by any provider
      # that is not OpenAI, which leaves the child with an empty task
      envelope = %{
        "type" => "agent_message",
        "id" => "amsg_1",
        "author" => "/root",
        "recipient" => "/root/read_a",
        "content" => [
          %{
            "type" => "input_text",
            "text" => "Message Type: NEW_TASK\nTask name: /root/read_a\nSender: /root\nPayload:\n"
          },
          %{
            "type" => "encrypted_content",
            "encrypted_content" => "Read a.txt and report its content."
          }
        ]
      }

      {:ok, up} = Gateway.prepare(with_input([@message, envelope]), @target)

      assert [
               @message,
               %{
                 "type" => "message",
                 "role" => "user",
                 "content" => [
                   %{
                     "type" => "input_text",
                     "text" =>
                       "Message Type: NEW_TASK\nTask name: /root/read_a\nSender: /root\nPayload:\n"
                   },
                   %{"type" => "input_text", "text" => "Read a.txt and report its content."}
                 ]
               }
             ] = up.body["input"]

      # OpenAI understands the item as codex sends it
      {:ok, up} = Gateway.prepare(with_input([envelope]), openai())
      assert up.body["input"] == [envelope]
    end

    test "strip_all_encrypted/1 is what the degraded retry sends" do
      body = with_input([@openai_item, @deepseek_item])
      stripped = Gateway.strip_all_encrypted(body)
      assert Enum.all?(stripped["input"], &(not Map.has_key?(&1, "encrypted_content")))
      assert length(stripped["input"]) == 2
    end
  end

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

    test "provider-hosted web_search tools only reach a provider that runs them" do
      body =
        Map.put(@codex_body, "tools", [
          %{"type" => "function", "name" => "exec_command", "parameters" => %{}},
          %{"type" => "web_search"},
          %{"type" => "web_search_preview", "search_context_size" => "low"}
        ])

      {:ok, up} = Gateway.prepare(body, @target)
      assert Enum.map(up.body["tools"], & &1["type"]) == ["function"]

      hosted = %Target{@target | hosted_web_search?: true}
      {:ok, up} = Gateway.prepare(body, hosted)
      assert up.body["tools"] == body["tools"]
    end

    test "the model's max_output_tokens is applied unless codex set one" do
      {:ok, up} = Gateway.prepare(@codex_body, @target)
      refute Map.has_key?(up.body, "max_output_tokens")

      capped = %Target{@target | max_output_tokens: 4_096}
      {:ok, up} = Gateway.prepare(@codex_body, capped)
      assert up.body["max_output_tokens"] == 4_096

      {:ok, up} = Gateway.prepare(Map.put(@codex_body, "max_output_tokens", 100), capped)
      assert up.body["max_output_tokens"] == 100
    end

    test "the upstream carries the provider's timeout and concurrency limit" do
      target = %Target{@target | request_timeout_ms: 30_000, max_concurrent_requests: 2}
      {:ok, up} = Gateway.prepare(@codex_body, target)
      assert up.receive_timeout == 30_000
      assert up.max_concurrent == 2
      assert up.provider_slug == "deepseek"
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
