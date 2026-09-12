defmodule Longx.Codex.ThreadStateTest do
  use ExUnit.Case, async: true

  alias Longx.Codex.ThreadState
  alias Longx.Codex.ThreadState.Store

  defp new_thread, do: "thread-#{System.unique_integer([:positive])}"

  defp item_started(t, item, turn \\ "turn-1"),
    do: Store.fold(t, "item/started", %{"threadId" => t, "turnId" => turn, "item" => item})

  defp item_completed(t, item, turn \\ "turn-1"),
    do: Store.fold(t, "item/completed", %{"threadId" => t, "turnId" => turn, "item" => item})

  describe "Store (ETS-backed view)" do
    test "thread and turn lifecycle" do
      t = new_thread()
      Store.fold(t, "thread/started", %{"thread" => %{"id" => t, "preview" => ""}})
      Store.fold(t, "turn/started", %{"turn" => %{"id" => "turn-1", "status" => "inProgress"}})

      assert Store.meta(t).thread["id"] == t
      assert Store.meta(t).turn == %{"id" => "turn-1", "status" => "inProgress"}

      Store.fold(t, "turn/completed", %{"turn" => %{"id" => "turn-1", "status" => "completed"}})
      assert Store.meta(t).turn["status"] == "completed"
    end

    test "agent message deltas accumulate into the item; completion replaces it" do
      t = new_thread()
      item_started(t, %{"id" => "m1", "type" => "agentMessage", "text" => ""})
      Store.fold(t, "item/agentMessage/delta", %{"itemId" => "m1", "delta" => "Hel"})
      Store.fold(t, "item/agentMessage/delta", %{"itemId" => "m1", "delta" => "lo"})

      assert [%{"id" => "m1", "text" => "Hello", "turnId" => "turn-1"}] = Store.items(t)

      item_completed(t, %{"id" => "m1", "type" => "agentMessage", "text" => "Hello!"})
      assert [%{"text" => "Hello!"}] = Store.items(t)
    end

    test "reasoning, command output and plan deltas accumulate" do
      t = new_thread()
      item_started(t, %{"id" => "r1", "type" => "reasoning"})
      Store.fold(t, "item/reasoning/summaryTextDelta", %{"itemId" => "r1", "delta" => "think"})
      Store.fold(t, "item/reasoning/textDelta", %{"itemId" => "r1", "delta" => "raw"})
      item_started(t, %{"id" => "c1", "type" => "commandExecution", "command" => "ls"})
      Store.fold(t, "item/commandExecution/outputDelta", %{"itemId" => "c1", "delta" => "a\n"})
      Store.fold(t, "item/commandExecution/outputDelta", %{"itemId" => "c1", "delta" => "b\n"})
      item_started(t, %{"id" => "p1", "type" => "plan"})
      Store.fold(t, "item/plan/delta", %{"itemId" => "p1", "delta" => "1. x"})

      assert [
               %{"id" => "r1", "summary" => "think", "content" => "raw"},
               %{"id" => "c1", "aggregatedOutput" => "a\nb\n"},
               %{"id" => "p1", "text" => "1. x"}
             ] = Store.items(t)
    end

    test "a delta for an item we never saw creates a placeholder so nothing is lost" do
      t = new_thread()
      Store.fold(t, "item/agentMessage/delta", %{"itemId" => "ghost", "delta" => "x"})
      assert [%{"id" => "ghost", "text" => "x"}] = Store.items(t)
    end

    test "items keep arrival order across turns and are isolated per thread" do
      t = new_thread()
      other = new_thread()
      item_started(t, %{"id" => "a", "type" => "userMessage"}, "turn-1")
      item_started(other, %{"id" => "zzz", "type" => "userMessage"})
      item_started(t, %{"id" => "b", "type" => "agentMessage"}, "turn-1")
      item_started(t, %{"id" => "c", "type" => "userMessage"}, "turn-2")

      assert Enum.map(Store.items(t), & &1["id"]) == ["a", "b", "c"]
      assert Enum.map(Store.items(other), & &1["id"]) == ["zzz"]
    end

    test "pending server requests are tracked until resolved" do
      t = new_thread()
      Store.put_request(t, 9, "item/commandExecution/requestApproval", %{"command" => "rm -rf /"})

      assert [
               %{
                 id: 9,
                 method: "item/commandExecution/requestApproval",
                 params: %{"command" => "rm -rf /"}
               }
             ] = Store.requests(t)

      Store.delete_request(t, 9)
      assert Store.requests(t) == []
    end

    test "token usage and thread status are kept" do
      t = new_thread()
      Store.fold(t, "thread/tokenUsage/updated", %{"tokenUsage" => %{"total" => 12}})

      Store.fold(t, "thread/status/changed", %{
        "status" => %{"type" => "active", "activeFlags" => ["waitingOnApproval"]}
      })

      assert Store.meta(t).token_usage == %{"total" => 12}
      assert Store.meta(t).status == %{"type" => "active", "activeFlags" => ["waitingOnApproval"]}
    end

    test "unknown notifications change nothing" do
      t = new_thread()
      before = Store.snapshot(t)
      Store.fold(t, "something/new", %{"x" => 1})
      assert Store.snapshot(t) == before
    end

    test "backfill/2 loads turns and items from a thread/read result" do
      t = new_thread()

      Store.backfill(t, %{
        "thread" => %{
          "id" => t,
          "turns" => [
            %{
              "id" => "turn-1",
              "status" => "completed",
              "items" => [
                %{"id" => "u1", "type" => "userMessage"},
                %{"id" => "m1", "type" => "agentMessage", "text" => "hi"}
              ]
            },
            %{
              "id" => "turn-2",
              "status" => "inProgress",
              "items" => [%{"id" => "u2", "type" => "userMessage"}]
            }
          ]
        }
      })

      assert Enum.map(Store.items(t), &{&1["id"], &1["turnId"]}) == [
               {"u1", "turn-1"},
               {"m1", "turn-1"},
               {"u2", "turn-2"}
             ]

      assert Store.meta(t).turn["id"] == "turn-2"
      assert Store.meta(t).thread["id"] == t
    end

    test "delete/1 drops everything for the thread" do
      t = new_thread()
      item_started(t, %{"id" => "a", "type" => "userMessage"})
      Store.put_request(t, 1, "m", %{})
      Store.delete(t)
      assert Store.items(t) == []
      assert Store.requests(t) == []
      assert Store.snapshot(t).seq == 0
    end
  end

  describe "ThreadState process" do
    setup do
      thread_id = new_thread()
      {:ok, pid} = ThreadState.ensure(thread_id)
      on_exit(fn -> if Process.alive?(pid), do: ThreadState.stop(thread_id) end)
      %{thread_id: thread_id, pid: pid}
    end

    test "ensure/1 is idempotent and lookup works", %{thread_id: thread_id, pid: pid} do
      assert {:ok, ^pid} = ThreadState.ensure(thread_id)
      assert ThreadState.whereis(thread_id) == pid
      assert ThreadState.whereis("nope") == nil
    end

    test "ingested events are folded, numbered and broadcast in order", %{thread_id: thread_id} do
      ThreadState.subscribe(thread_id)

      ThreadState.ingest(thread_id, "turn/started", %{
        "turn" => %{"id" => "turn-1", "status" => "inProgress"}
      })

      ThreadState.ingest(thread_id, "item/started", %{
        "turnId" => "turn-1",
        "item" => %{"id" => "m1", "type" => "agentMessage", "text" => ""}
      })

      ThreadState.ingest(thread_id, "item/agentMessage/delta", %{
        "itemId" => "m1",
        "delta" => "hi"
      })

      assert_receive {:codex, 1, "turn/started", _}
      assert_receive {:codex, 2, "item/started", _}
      assert_receive {:codex, 3, "item/agentMessage/delta", %{"delta" => "hi"}}

      snapshot = ThreadState.snapshot(thread_id)
      assert snapshot.seq == 3
      assert snapshot.turn["id"] == "turn-1"
      assert [%{"id" => "m1", "text" => "hi"}] = snapshot.items
    end

    test "snapshot reads ETS directly: it works even when the thread process is gone", %{
      thread_id: thread_id
    } do
      ThreadState.ingest(thread_id, "item/started", %{
        "turnId" => "t",
        "item" => %{"id" => "m1", "type" => "agentMessage", "text" => "kept"}
      })

      ThreadState.subscribe(thread_id)
      assert_receive {:codex, 1, "item/started", _}

      ThreadState.stop(thread_id)
      assert ThreadState.whereis(thread_id) == nil
      assert [%{"text" => "kept"}] = ThreadState.snapshot(thread_id).items
      assert ThreadState.snapshot(thread_id).seq == 1

      # and a restarted process continues the sequence instead of restarting it
      {:ok, _} = ThreadState.ensure(thread_id)

      ThreadState.ingest(thread_id, "item/agentMessage/delta", %{"itemId" => "m1", "delta" => "!"})

      assert_receive {:codex, 2, "item/agentMessage/delta", _}
    end

    test "subscribe-then-snapshot never loses or duplicates events", %{thread_id: thread_id} do
      producer =
        Task.async(fn ->
          for i <- 1..50 do
            ThreadState.ingest(thread_id, "item/agentMessage/delta", %{
              "itemId" => "m",
              "delta" => "#{i},"
            })

            if rem(i, 10) == 0, do: Process.sleep(5)
          end
        end)

      Process.sleep(12)
      ThreadState.subscribe(thread_id)
      snapshot = ThreadState.snapshot(thread_id)
      Task.await(producer)

      live =
        Stream.repeatedly(fn ->
          receive do
            {:codex, seq, _m, %{"delta" => d}} -> {seq, d}
          after
            200 -> nil
          end
        end)
        |> Enum.take_while(&(&1 != nil))

      applied =
        live |> Enum.filter(fn {seq, _} -> seq > snapshot.seq end) |> Enum.map(&elem(&1, 1))

      [%{"text" => text}] = snapshot.items
      assert text <> Enum.join(applied) == Enum.map_join(1..50, &"#{&1},")

      seqs = Enum.map(live, &elem(&1, 0))
      assert seqs == Enum.to_list(hd(seqs)..List.last(seqs)//1)
    end

    test "server requests show up in the snapshot until resolved", %{thread_id: thread_id} do
      ThreadState.subscribe(thread_id)

      ThreadState.put_request(thread_id, 42, "item/commandExecution/requestApproval", %{
        "command" => "ls"
      })

      assert_receive {:codex, 1, "item/commandExecution/requestApproval",
                      %{"requestId" => 42, "command" => "ls"}}

      assert [%{id: 42}] = ThreadState.snapshot(thread_id).pending_requests

      ThreadState.resolve_request(thread_id, 42)
      assert_receive {:codex, 2, "serverRequest/resolved", %{"requestId" => 42}}
      assert ThreadState.snapshot(thread_id).pending_requests == []
    end

    test "backfill seeds the view", %{thread_id: thread_id} do
      ThreadState.backfill(thread_id, %{
        "thread" => %{
          "id" => thread_id,
          "turns" => [
            %{
              "id" => "t1",
              "status" => "completed",
              "items" => [%{"id" => "x", "type" => "userMessage"}]
            }
          ]
        }
      })

      assert [%{"id" => "x"}] = ThreadState.snapshot(thread_id).items
    end
  end
end
