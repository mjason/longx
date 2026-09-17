defmodule Longx.Agent.TranscriptTest do
  use Longx.DataCase, async: false

  alias Longx.Agent.Transcript

  @thread "th-#{System.unique_integer([:positive])}"

  test "items are appended in sequence, listed in order, truncated per turn and deleted per thread" do
    user = %{"type" => "message", "role" => "user", "content" => "hi"}
    call = %{"type" => "function_call", "call_id" => "c1", "name" => "exec", "arguments" => "{}"}
    out = %{"type" => "function_call_output", "call_id" => "c1", "output" => "ok"}

    Transcript.append!(%{
      thread_id: @thread,
      turn_id: "t1",
      seq: 1,
      kind: :user_message,
      input: user,
      ui: %{"type" => "userMessage"}
    })

    Transcript.append!(%{
      thread_id: @thread,
      turn_id: "t2",
      seq: 3,
      kind: :function_call_output,
      input: out
    })

    Transcript.append!(%{
      thread_id: @thread,
      turn_id: "t2",
      seq: 2,
      kind: :function_call,
      input: call,
      ui: %{"type" => "commandExecution"},
      model: "m"
    })

    items = Transcript.items!(@thread)
    assert Enum.map(items, & &1.seq) == [1, 2, 3]
    assert Enum.map(items, & &1.kind) == [:user_message, :function_call, :function_call_output]
    assert Enum.at(items, 1).model == "m"
    assert Enum.at(items, 2).ui == nil

    assert Transcript.input(items) == [user, call, out]
    assert Transcript.last_seq(@thread) == 3

    Transcript.truncate!(@thread, "t2")
    assert Enum.map(Transcript.items!(@thread), & &1.seq) == [1]

    Transcript.delete!(@thread)
    assert Transcript.items!(@thread) == []
    assert Transcript.last_seq(@thread) == 0
  end

  test "a function call left without an output is closed on load" do
    call = %{"type" => "function_call", "call_id" => "c9", "name" => "exec", "arguments" => "{}"}

    Transcript.append!(%{
      thread_id: @thread <> "b",
      turn_id: "t1",
      seq: 1,
      kind: :function_call,
      input: call
    })

    assert [
             %{"type" => "function_call"},
             %{"type" => "function_call_output", "call_id" => "c9", "output" => output}
           ] =
             Transcript.items!(@thread <> "b") |> Transcript.input()

    assert output =~ "interrupted"
  end

  test "a message that landed between a call's siblings and their outputs is moved after the outputs" do
    id = @thread <> "c"

    call = fn n ->
      %{"type" => "function_call", "call_id" => n, "name" => "x", "arguments" => "{}"}
    end

    out = fn n -> %{"type" => "function_call_output", "call_id" => n, "output" => "ok"} end

    image = %{
      "type" => "message",
      "role" => "user",
      "content" => [%{"type" => "input_image", "image_url" => "data:x"}]
    }

    user = %{
      "type" => "message",
      "role" => "user",
      "content" => [%{"type" => "input_text", "text" => "hi"}]
    }

    rows = [
      {:user_message, user},
      {:function_call, call.("a")},
      {:function_call, call.("b")},
      {:function_call_output, out.("b")},
      {:user_message, image},
      {:function_call_output, out.("a")},
      {:agent_message, %{"type" => "message", "role" => "assistant", "content" => []}}
    ]

    for {{kind, input}, i} <- Enum.with_index(rows, 1),
        do: Transcript.append!(%{thread_id: id, turn_id: "t", seq: i, kind: kind, input: input})

    assert [
             ^user,
             %{"call_id" => "a", "type" => "function_call"},
             %{"call_id" => "b", "type" => "function_call"},
             %{"call_id" => "b", "type" => "function_call_output"},
             %{"call_id" => "a", "type" => "function_call_output"},
             ^image,
             %{"role" => "assistant"}
           ] = Transcript.input(Transcript.items!(id))
  end
end
