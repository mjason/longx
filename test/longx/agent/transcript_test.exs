defmodule Longx.Agent.TranscriptTest do
  use Longx.DataCase, async: false

  alias Longx.Agent.Transcript

  @thread "th-#{System.unique_integer([:positive])}"

  test "a write that meets SQLite's lock is tried again before it fails (a locked database once crashed the agent mid-turn)" do
    # a writer that is refused twice, then goes through
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    write = fn ->
      n = Agent.get_and_update(counter, &{&1, &1 + 1})
      if n < 2, do: raise(locked()), else: :written
    end

    assert :written == Transcript.write_with_retry(write, waits: [1, 1, 1])
    assert Agent.get(counter, & &1) == 3

    # not a lock: raised as it is, at once
    assert_raise ArgumentError, fn ->
      Transcript.write_with_retry(fn -> raise ArgumentError, "other" end, waits: [1])
    end

    # still locked after every wait: the last error is the one raised
    assert_raise Ash.Error.Unknown, fn ->
      Transcript.write_with_retry(fn -> raise(locked()) end, waits: [1, 1])
    end
  end

  # the error as Ash raises it around Exqlite's
  defp locked,
    do:
      Ash.Error.to_error_class(%Exqlite.Error{
        message: "database is locked",
        statement: "BEGIN IMMEDIATE TRANSACTION"
      })

  test "every append goes through one writer as an event: appended from many processes at once, written in batches, read back whole and in order; a read, a truncate or a delete flushes first" do
    alias Longx.Agent.Transcript.Writer
    threads = for n <- 1..8, do: "w-#{n}-#{System.unique_integer([:positive])}"

    tasks =
      for thread <- threads do
        Task.async(fn ->
          for seq <- 1..40 do
            Transcript.append!(%{
              thread_id: thread,
              turn_id: "t1",
              seq: seq,
              kind: :user_message,
              input: %{
                "role" => "user",
                "content" => [%{"type" => "input_text", "text" => "m#{seq}"}]
              },
              ui: %{"id" => "i#{seq}", "type" => "userMessage"}
            })
          end
        end)
      end

    Enum.each(tasks, &Task.await/1)
    # nothing was written by the appenders themselves: the writer wrote it, in few transactions
    assert Writer.flush() == :ok
    assert Writer.stats().batches < 8 * 40
    assert Writer.stats().written >= 8 * 40

    for thread <- threads do
      assert Enum.map(Transcript.items!(thread), & &1.seq) == Enum.to_list(1..40)
    end

    # queued, then read at once: the read sees it (it flushes first)
    [thread | _] = threads

    Transcript.append!(%{
      thread_id: thread,
      turn_id: "t2",
      seq: 41,
      kind: :user_message,
      input: %{"role" => "user", "content" => []},
      ui: nil
    })

    assert Transcript.last_seq(thread) == 41
    # queued, then truncated at once: gone, and it does not come back with a later flush
    Transcript.append!(%{
      thread_id: thread,
      turn_id: "t3",
      seq: 42,
      kind: :user_message,
      input: %{"role" => "user", "content" => []},
      ui: nil
    })

    Transcript.truncate!(thread, "t3")
    assert Writer.flush() == :ok
    assert Transcript.last_seq(thread) == 41
    Transcript.delete!(thread)
    assert Transcript.items!(thread) == []
  end

  test "a batch the lock refuses is written on the next try; an error that is no lock drops the batch and is recorded, never raised into an agent" do
    alias Longx.Agent.Transcript.Writer
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    # the writer's write function is the batch: refused twice by "the lock", then through
    writer = fn batch ->
      n = Agent.get_and_update(counter, &{&1, &1 + 1})
      if n < 2, do: raise(locked()), else: {:ok, length(batch)}
    end

    {:ok, pid} = Writer.start_link(name: nil, write: writer, waits: [1, 1, 1])
    GenServer.cast(pid, {:append, %{seq: 1}})
    assert :ok = GenServer.call(pid, :flush)
    assert Agent.get(counter, & &1) == 3
    assert GenServer.call(pid, :stats).written == 1

    # a bug is not retried: the batch is dropped with a fault, the writer lives on
    bad = fn _batch -> raise ArgumentError, "no such column" end
    {:ok, pid} = Writer.start_link(name: nil, write: bad, waits: [1])
    GenServer.cast(pid, {:append, %{seq: 1}})
    # dropped, counted, and the flush answers (a reader raising would help nobody)
    assert :ok = GenServer.call(pid, :flush)
    assert GenServer.call(pid, :stats).dropped == 1
    assert Process.alive?(pid)
  end

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
