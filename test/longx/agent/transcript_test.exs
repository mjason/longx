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
end
