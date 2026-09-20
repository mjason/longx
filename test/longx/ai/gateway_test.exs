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
      # readable reasoning stays (its id does not: 百炼 would refuse an rs_ id)
      assert Enum.any?(up.body["input"], &(&1["summary"] == @openai_item["summary"]))
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

  describe "prepare/2 item ids — a provider only ever gets ids it can read" do
    @ids_input [
      %{
        "type" => "message",
        "role" => "assistant",
        "id" => "ff1a7b42-0a32-45e2-ab9a-88df74315fb1",
        "content" => [%{"type" => "output_text", "text" => "deepseek said"}]
      },
      %{
        "type" => "message",
        "role" => "assistant",
        "id" => "msg_165c58d2-dec4-4202-a44a-3d256f7f7ff1",
        "content" => [%{"type" => "output_text", "text" => "qwen said"}]
      },
      %{
        "type" => "message",
        "role" => "assistant",
        "id" => "msg_67c9a1b2c3d4e5f60718293a4b5c6d7e8f90",
        "content" => [%{"type" => "output_text", "text" => "openai said"}]
      },
      %{
        "type" => "function_call",
        "id" => "fc_67c9a1b2c3d4e5f60718293a4b5c6d7e8f90",
        "call_id" => "call_1",
        "name" => "ping",
        "arguments" => "{}"
      },
      %{
        "type" => "function_call",
        "id" => "bef933f7-4d8a-4f6e-9c1d-2a3b4c5d6e7f",
        "call_id" => "call_2",
        "name" => "ping",
        "arguments" => "{}"
      },
      %{"type" => "function_call_output", "call_id" => "call_2", "output" => "pong"}
    ]

    # 百炼 answers 400 "message id must be a string starting with msg_" to a
    # DeepSeek uuid; DeepSeek and 百炼 both take an item without an id
    test "non-OpenAI target: every item id goes, whoever produced it" do
      {:ok, up} = Gateway.prepare(with_input(@ids_input), @target)
      assert length(up.body["input"]) == 6
      refute Enum.any?(up.body["input"], &Map.has_key?(&1, "id"))

      assert Enum.map(up.body["input"], & &1["call_id"]) == [
               nil,
               nil,
               nil,
               "call_1",
               "call_2",
               "call_2"
             ]
    end

    test "OpenAI target: only its own msg_/fc_/rs_ ids stay — a uuid, or 百炼's msg_<uuid>, is dropped" do
      {:ok, up} = Gateway.prepare(with_input(@ids_input ++ [@openai_item]), openai())

      assert Enum.map(up.body["input"], & &1["id"]) == [
               nil,
               nil,
               "msg_67c9a1b2c3d4e5f60718293a4b5c6d7e8f90",
               "fc_67c9a1b2c3d4e5f60718293a4b5c6d7e8f90",
               nil,
               nil,
               "rs_abc"
             ]
    end
  end

  describe "prepare/2" do
    test "targets <base_url>/responses with the provider's credentials" do
      {:ok, up} = Gateway.prepare(@codex_body, @target)

      assert up.url == "https://api.deepseek.com/v1/responses"
      assert {"authorization", "Bearer sk-ds"} in up.headers
      assert {"accept", "text/event-stream"} in up.headers
    end

    test "a ChatGPT-subscription target: the codex backend's headers, store false, the encrypted reasoning asked back" do
      chatgpt = %Target{
        @target
        | kind: :openai,
          chatgpt?: true,
          account_id: "acct-123",
          base_url: "https://chatgpt.com/backend-api/codex",
          api_key: "jwt"
      }

      {:ok, up} = Gateway.prepare(@codex_body, chatgpt)
      assert up.url == "https://chatgpt.com/backend-api/codex/responses"
      assert {"authorization", "Bearer jwt"} in up.headers
      assert {"chatgpt-account-id", "acct-123"} in up.headers
      assert {"openai-beta", "responses=experimental"} in up.headers
      assert {"originator", "codex_cli_rs"} in up.headers
      assert up.body["store"] == false
      assert up.body["include"] == ["reasoning.encrypted_content"]
      # an ordinary target gets none of it
      {:ok, plain} = Gateway.prepare(Map.drop(@codex_body, ["store", "include"]), @target)
      refute Map.has_key?(plain.body, "store")
      refute Map.has_key?(plain.body, "include")
      refute Enum.any?(plain.headers, &(elem(&1, 0) in ["chatgpt-account-id", "originator"]))
    end

    test "a ChatGPT-subscription target gets no output-only fields back on replayed items (the backend answers 400 to `input[1].status`)" do
      chatgpt = %Target{
        @target
        | kind: :openai,
          chatgpt?: true,
          account_id: "a",
          base_url: "https://chatgpt.com/backend-api/codex"
      }

      body =
        Map.put(@codex_body, "input", [
          %{
            "type" => "message",
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => "hi"}]
          },
          %{
            "type" => "message",
            "id" => "msg_1",
            "role" => "assistant",
            "status" => "completed",
            "phase" => "final_answer",
            "content" => [
              %{"type" => "output_text", "text" => "yo", "annotations" => [], "logprobs" => []}
            ]
          },
          %{
            "type" => "function_call",
            "id" => "fc_1",
            "call_id" => "c1",
            "name" => "exec_command",
            "arguments" => "{}",
            "status" => "completed"
          },
          %{"type" => "function_call_output", "call_id" => "c1", "output" => "ok"}
        ])

      {:ok, up} = Gateway.prepare(body, chatgpt)
      [_, message, call, _] = up.body["input"]
      refute Map.has_key?(message, "status")
      refute Map.has_key?(message, "phase")
      refute Map.has_key?(hd(message["content"]), "logprobs")
      assert hd(message["content"])["text"] == "yo"
      refute Map.has_key?(call, "status")
      assert call["call_id"] == "c1"
      # api.openai.com takes them as they are
      {:ok, plain} = Gateway.prepare(body, %Target{@target | kind: :openai})
      assert Enum.at(plain.body["input"], 1)["status"] == "completed"
    end

    test "the hosted image_generation tool goes only to a model flagged for it; a stray one is dropped for the rest" do
      body =
        Map.put(@codex_body, "tools", [
          %{"type" => "function", "name" => "exec_command", "parameters" => %{}}
        ])

      {:ok, plain} = Gateway.prepare(body, @target)
      refute Enum.any?(plain.body["tools"], &(&1["type"] == "image_generation"))

      {:ok, drawing} = Gateway.prepare(body, %Target{@target | image_generation?: true})
      assert Enum.map(drawing.body["tools"], & &1["type"]) == ["function", "image_generation"]

      # once is enough; a request already carrying it keeps one
      {:ok, twice} = Gateway.prepare(drawing.body, %Target{@target | image_generation?: true})
      assert Enum.count(twice.body["tools"], &(&1["type"] == "image_generation")) == 1
      # a replayed image_generation_call item never reaches a target without the tool
      replay =
        Map.put(
          body,
          "input",
          body["input"] ++
            [%{"type" => "image_generation_call", "id" => "ig_1", "result" => "AAAA"}]
        )

      {:ok, stripped} = Gateway.prepare(replay, @target)
      refute Enum.any?(stripped.body["input"], &(&1["type"] == "image_generation_call"))
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

    test "the model's reasoning summary is applied: the row's choice replaces the kernel's auto, none drops the summary, unset leaves it" do
      body = Map.put(@codex_body, "reasoning", %{"effort" => "high", "summary" => "auto"})
      {:ok, up} = Gateway.prepare(body, @target)
      assert up.body["reasoning"] == %{"effort" => "high", "summary" => "auto"}

      {:ok, up} = Gateway.prepare(body, %Target{@target | reasoning_summary: :detailed})
      assert up.body["reasoning"] == %{"effort" => "high", "summary" => "detailed"}

      {:ok, up} = Gateway.prepare(body, %Target{@target | reasoning_summary: :none})
      assert up.body["reasoning"] == %{"effort" => "high"}

      # a request without a reasoning block is left alone
      {:ok, up} =
        Gateway.prepare(Map.delete(@codex_body, "reasoning"), %Target{
          @target
          | reasoning_summary: :detailed
        })

      refute Map.has_key?(up.body, "reasoning")
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

  test "a provider's own web_search_call items are dropped for a target that does not search" do
    body = %{
      "model" => "longx",
      "input" => [
        %{"type" => "message", "role" => "user", "content" => "hi"},
        %{
          "type" => "web_search_call",
          "id" => "ws_1",
          "status" => "completed",
          "action" => %{"type" => "search", "query" => "x"}
        },
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => "found"}]
        }
      ]
    }

    {:ok, up} = Gateway.prepare(body, @target)
    assert Enum.map(up.body["input"], & &1["type"]) == ["message", "message"]

    {:ok, up} = Gateway.prepare(body, %{@target | hosted_web_search?: true})
    assert Enum.map(up.body["input"], & &1["type"]) == ["message", "web_search_call", "message"]
  end
end
