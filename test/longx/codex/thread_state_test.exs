defmodule Longx.Codex.ThreadStateTest do
  use ExUnit.Case, async: true

  alias Longx.Codex.ThreadState
  alias Longx.Codex.ThreadState.View

  defp item_started(item, turn \\ "turn-1"),
    do: {"item/started", %{"threadId" => "t", "turnId" => turn, "item" => item}}

  defp item_completed(item, turn \\ "turn-1"),
    do: {"item/completed", %{"threadId" => "t", "turnId" => turn, "item" => item}}

  describe "View.fold/3 (pure)" do
    test "thread and turn lifecycle" do
      view =
        View.new("t")
        |> View.fold("thread/started", %{"thread" => %{"id" => "t", "preview" => ""}})
        |> View.fold("turn/started", %{"turn" => %{"id" => "turn-1", "status" => "inProgress"}})

      assert view.thread["id"] == "t"
      assert view.turn == %{"id" => "turn-1", "status" => "inProgress"}

      view =
        View.fold(view, "turn/completed", %{
          "turn" => %{"id" => "turn-1", "status" => "completed"}
        })

      assert view.turn["status"] == "completed"
    end

    test "agent message deltas accumulate into the item; completion replaces it" do
      view =
        View.new("t")
        |> View.fold(item_started(%{"id" => "m1", "type" => "agentMessage", "text" => ""}))
        |> View.fold("item/agentMessage/delta", %{"itemId" => "m1", "delta" => "Hel"})
        |> View.fold("item/agentMessage/delta", %{"itemId" => "m1", "delta" => "lo"})

      assert [%{"id" => "m1", "text" => "Hello", "turnId" => "turn-1"}] = View.items(view)

      view =
        View.fold(
          view,
          item_completed(%{"id" => "m1", "type" => "agentMessage", "text" => "Hello!"})
        )

      assert [%{"text" => "Hello!"}] = View.items(view)
    end

    test "reasoning, command output and plan deltas accumulate" do
      view =
        View.new("t")
        |> View.fold(item_started(%{"id" => "r1", "type" => "reasoning"}))
        |> View.fold("item/reasoning/summaryTextDelta", %{"itemId" => "r1", "delta" => "think"})
        |> View.fold("item/reasoning/textDelta", %{"itemId" => "r1", "delta" => "raw"})
        |> View.fold(
          item_started(%{"id" => "c1", "type" => "commandExecution", "command" => "ls"})
        )
        |> View.fold("item/commandExecution/outputDelta", %{"itemId" => "c1", "delta" => "a\n"})
        |> View.fold("item/commandExecution/outputDelta", %{"itemId" => "c1", "delta" => "b\n"})
        |> View.fold(item_started(%{"id" => "p1", "type" => "plan"}))
        |> View.fold("item/plan/delta", %{"itemId" => "p1", "delta" => "1. x"})

      assert [
               %{"id" => "r1", "summary" => "think", "content" => "raw"},
               %{"id" => "c1", "aggregatedOutput" => "a\nb\n"},
               %{"id" => "p1", "text" => "1. x"}
             ] =
               View.items(view)
    end

    test "a delta for an item we never saw creates a placeholder so nothing is lost" do
      view =
        View.fold(View.new("t"), "item/agentMessage/delta", %{"itemId" => "ghost", "delta" => "x"})

      assert [%{"id" => "ghost", "text" => "x"}] = View.items(view)
    end

    test "items keep arrival order across turns" do
      view =
        View.new("t")
        |> View.fold(item_started(%{"id" => "a", "type" => "userMessage"}, "turn-1"))
        |> View.fold(item_started(%{"id" => "b", "type" => "agentMessage"}, "turn-1"))
        |> View.fold(item_started(%{"id" => "c", "type" => "userMessage"}, "turn-2"))

      assert Enum.map(View.items(view), & &1["id"]) == ["a", "b", "c"]
    end

    test "pending server requests are tracked until resolved" do
      view =
        View.new("t")
        |> View.put_request(9, "item/commandExecution/requestApproval", %{"command" => "rm -rf /"})

      assert [
               %{
                 id: 9,
                 method: "item/commandExecution/requestApproval",
                 params: %{"command" => "rm -rf /"}
               }
             ] = View.pending_requests(view)

      assert View.pending_requests(View.resolve_request(view, 9)) == []
    end

    test "token usage and thread status are kept" do
      view =
        View.new("t")
        |> View.fold("thread/tokenUsage/updated", %{"tokenUsage" => %{"total" => 12}})
        |> View.fold("thread/status/changed", %{
          "status" => %{"type" => "active", "activeFlags" => ["waitingOnApproval"]}
        })

      assert view.token_usage == %{"total" => 12}
      assert view.status == %{"type" => "active", "activeFlags" => ["waitingOnApproval"]}
    end

    test "unknown notifications are ignored" do
      view = View.new("t")
      assert View.fold(view, "something/new", %{"x" => 1}) == view
    end

    test "backfill/2 loads turns and items from a thread/read result" do
      read = %{
        "thread" => %{
          "id" => "t",
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
      }

      view = View.backfill(View.new("t"), read)

      assert Enum.map(View.items(view), &{&1["id"], &1["turnId"]}) == [
               {"u1", "turn-1"},
               {"m1", "turn-1"},
               {"u2", "turn-2"}
             ]

      assert view.turn["id"] == "turn-2"
      assert view.thread["id"] == "t"
    end
  end

  describe "ThreadState process" do
    setup do
      thread_id = "thread-#{System.unique_integer([:positive])}"
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

    test "subscribe-then-snapshot never loses or duplicates events", %{thread_id: thread_id} do
      # a producer streams deltas while a late client connects mid-stream
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
      rebuilt = text <> Enum.join(applied)

      assert rebuilt == Enum.map_join(1..50, &"#{&1},")

      # strictly consecutive seqs on the wire
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
