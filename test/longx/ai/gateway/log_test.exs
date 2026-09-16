defmodule Longx.AI.Gateway.LogTest do
  # the gateway's memory of its last requests — what a person (or Claude) reads
  # to see whether codex asked for what the UI promised
  use ExUnit.Case, async: false

  alias Longx.AI.Gateway.Log

  setup do
    Log.clear()
    :ok
  end

  test "an entry is taken from the request body and codex's metadata, then finished with the outcome" do
    body = %{
      "model" => "deepseek-flash",
      "reasoning" => %{"effort" => "low", "summary" => "auto"},
      "instructions" => "be brief",
      "input" => [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [%{"type" => "input_text", "text" => "hi"}]
        }
      ],
      "tools" => [
        %{"type" => "function", "name" => "exec_command"},
        %{"type" => "namespace", "name" => "memory"}
      ],
      "max_output_tokens" => 4096,
      "client_metadata" => %{
        "thread_id" => "thr_1",
        "turn_id" => "turn_1",
        "x-codex-turn-metadata" => ~s({"request_kind":"agent","thread_source":"user"})
      }
    }

    id =
      Log.begin(body, %{
        slug: "deepseek-flash",
        upstream_id: "deepseek-v4-flash",
        provider: "deepseek"
      })

    assert [%{id: ^id, status: nil} = open] = Log.recent(10)
    assert open.thread_id == "thr_1"
    assert open.turn_id == "turn_1"
    assert open.request_kind == "agent"
    assert open.model == "deepseek-flash"
    assert open.upstream_id == "deepseek-v4-flash"
    assert open.provider == "deepseek"
    assert open.effort == "low"
    assert open.summary == "auto"
    assert open.tools == ["exec_command", "memory"]
    assert open.input_items == 1
    assert open.max_output_tokens == 4096
    assert open.instructions_chars == 8
    assert is_binary(open.at)

    Log.finish(id, %{status: 200, error: nil})
    assert [%{status: 200, duration_ms: ms, error: nil}] = Log.recent(10)
    assert is_integer(ms) and ms >= 0
  end

  test "a refused request is logged with its error; the log keeps the newest N" do
    id = Log.begin(%{"model" => "nope", "input" => []}, nil)
    Log.finish(id, %{status: 400, error: "unknown model"})

    assert [%{model: "nope", upstream_id: nil, status: 400, error: "unknown model"}] =
             Log.recent(10)

    for i <- 1..(Log.keep() + 5), do: Log.begin(%{"model" => "m#{i}", "input" => []}, nil)
    recent = Log.recent(Log.keep() + 100)
    assert length(recent) == Log.keep()
    # newest first
    assert hd(recent).model == "m#{Log.keep() + 5}"
    refute Enum.any?(recent, &(&1.model == "nope"))
  end
end
