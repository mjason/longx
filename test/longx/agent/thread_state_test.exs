defmodule Longx.Agent.ThreadStateTest do
  use ExUnit.Case, async: true

  alias Longx.Agent.ThreadState
  alias Longx.Agent.ThreadState.Store

  defp new_thread, do: "thread-#{System.unique_integer([:positive])}"

  defp item_started(t, item, turn \\ "turn-1"),
    do: Store.fold(t, "item/started", %{"threadId" => t, "turnId" => turn, "item" => item})

  defp item_completed(t, item, turn \\ "turn-1"),
    do: Store.fold(t, "item/completed", %{"threadId" => t, "turnId" => turn, "item" => item})

  defp paused_event(thread_id, write) do
    parent = self()

    writer =
      Task.async(fn ->
        Store.event(thread_id, fn ->
          send(parent, :writer_paused)
          receive do: (:finish_write -> write.())
        end)
      end)

    on_exit(fn ->
      Process.exit(writer.pid, :kill)
      Store.delete(thread_id)
    end)

    assert_receive :writer_paused, 2_000
    writer
  end

  defp reader(fun) do
    parent = self()

    task =
      Task.async(fn ->
        send(parent, :reader_started)
        fun.()
      end)

    on_exit(fn -> Process.exit(task.pid, :kill) end)
    assert_receive :reader_started, 2_000
    task
  end

  describe "Store (ETS-backed view)" do
    @tag :consistent_snapshot
    test "snapshot cannot return a new seq without its first item while the writer is paused" do
      t = new_thread()

      writer =
        paused_event(t, fn ->
          Store.fold(t, "item/agentMessage/delta", %{"itemId" => "m", "delta" => "1,"})
        end)

      snapshot = reader(fn -> Store.snapshot(t) end)
      read_ref = snapshot.ref
      refute_receive {^read_ref, _}, 200
      send(writer.pid, :finish_write)
      assert Task.await(writer) == 1
      assert %{seq: 1, items: [%{"id" => "m", "text" => "1,"}]} = Task.await(snapshot)
    end

    @tag :consistent_snapshot
    test "earlier pages also wait for an in-progress item update instead of returning stale contents" do
      t = new_thread()
      item_completed(t, %{"id" => "m1", "type" => "agentMessage", "text" => "old"})
      item_completed(t, %{"id" => "m2", "type" => "agentMessage", "text" => "tail"})

      writer =
        paused_event(t, fn ->
          Store.fold(t, "item/agentMessage/delta", %{"itemId" => "m1", "delta" => "-new"})
        end)

      page = reader(fn -> Store.earlier(t, "m2", :all) end)
      read_ref = page.ref
      refute_receive {^read_ref, _}, 200
      send(writer.pid, :finish_write)
      assert Task.await(writer) == 1
      assert {:ok, %{items: [%{"id" => "m1", "text" => "old-new"}]}} = Task.await(page)
    end

    @tag :consistent_snapshot
    test "a writer that never completes causes an explicit read failure, never an inconsistent snapshot" do
      t = new_thread()
      paused_event(t, fn -> :ok end)

      snapshot =
        reader(fn ->
          try do
            Store.snapshot(t)
          rescue
            e in RuntimeError -> e
          end
        end)

      assert %RuntimeError{message: message} = Task.await(snapshot, 7_000)
      assert message =~ "consistent thread state"
    end

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

    test "reasoning and command output deltas accumulate" do
      t = new_thread()
      item_started(t, %{"id" => "r1", "type" => "reasoning"})
      Store.fold(t, "item/reasoning/summaryTextDelta", %{"itemId" => "r1", "delta" => "think"})
      Store.fold(t, "item/reasoning/textDelta", %{"itemId" => "r1", "delta" => "raw"})
      item_started(t, %{"id" => "c1", "type" => "commandExecution", "command" => "ls"})
      Store.fold(t, "item/commandExecution/outputDelta", %{"itemId" => "c1", "delta" => "a\n"})
      Store.fold(t, "item/commandExecution/outputDelta", %{"itemId" => "c1", "delta" => "b\n"})

      assert [
               %{"id" => "r1", "summary" => "think", "content" => "raw"},
               %{"id" => "c1", "aggregatedOutput" => "a\nb\n"}
             ] = Store.items(t)
    end

    test "bytes that are not UTF-8 never reach the view: a snapshot and every folded event stay JSON-encodable" do
      # a socket died on every join of a thread whose agent had cat'ed a binary:
      # the transport could not encode the snapshot and closed, the client
      # reconnected, and so on — 146 times in five seconds
      t = new_thread()

      item_started(t, %{
        "id" => "c1",
        "type" => "commandExecution",
        "command" => "cat data.parquet"
      })

      Store.fold(t, "item/commandExecution/outputDelta", %{
        "itemId" => "c1",
        "delta" => <<"PAR1", 0xFF, 0xFE, "x">>
      })

      item_completed(t, %{
        "id" => "c1",
        "type" => "commandExecution",
        "aggregatedOutput" => <<"PAR1", 0xFF, 0xFE, "x">>,
        "status" => "completed"
      })

      assert [%{"aggregatedOutput" => out}] = Store.items(t)
      assert String.valid?(out)
      assert out =~ "PAR1"
      assert out =~ "x"
      assert {:ok, _} = Jason.encode(Store.snapshot(t))

      # what a boot replays from the transcript goes through the same scrub
      t2 = new_thread()

      :ok =
        Store.backfill(t2, %{
          "thread" => %{
            "id" => t2,
            "turns" => [
              %{
                "id" => "turn-1",
                "items" => [%{"id" => "a1", "type" => "agentMessage", "text" => <<"hi", 0xC3>>}]
              }
            ]
          }
        })

      assert [%{"text" => text}] = Store.items(t2)
      assert String.valid?(text)
      assert {:ok, _} = Jason.encode(Store.snapshot(t2))
    end

    test "reasoning as codex sends it: summary/content are lists, deltas name their index" do
      t = new_thread()
      item_started(t, %{"id" => "r1", "type" => "reasoning", "summary" => [], "content" => []})

      Store.fold(t, "item/reasoning/summaryTextDelta", %{
        "itemId" => "r1",
        "delta" => "th",
        "summaryIndex" => 0
      })

      Store.fold(t, "item/reasoning/summaryTextDelta", %{
        "itemId" => "r1",
        "delta" => "ink",
        "summaryIndex" => 0
      })

      Store.fold(t, "item/reasoning/summaryTextDelta", %{
        "itemId" => "r1",
        "delta" => "more",
        "summaryIndex" => 1
      })

      Store.fold(t, "item/reasoning/textDelta", %{
        "itemId" => "r1",
        "delta" => "raw",
        "contentIndex" => 0
      })

      assert [%{"id" => "r1", "summary" => ["think", "more"], "content" => ["raw"]}] =
               Store.items(t)
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

    test "the thread's goal (codex's goal mode) is part of the view: updated replaces, cleared removes" do
      t = new_thread()

      goal = %{
        "threadId" => t,
        "objective" => "make it pass",
        "status" => "active",
        "tokenBudget" => 50_000,
        "tokensUsed" => 12,
        "timeUsedSeconds" => 3,
        "createdAt" => 1,
        "updatedAt" => 2
      }

      Store.fold(t, "thread/goal/updated", %{"threadId" => t, "turnId" => nil, "goal" => goal})
      assert Store.snapshot(t).goal == goal
      done = Map.put(goal, "status", "complete")
      Store.fold(t, "thread/goal/updated", %{"threadId" => t, "turnId" => "u1", "goal" => done})
      assert Store.snapshot(t).goal["status"] == "complete"
      Store.fold(t, "thread/goal/cleared", %{"threadId" => t})
      assert Store.snapshot(t).goal == nil
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

    # four turns of three items; turn-1 holds a sub-agent activity
    defp twelve_items(t) do
      for turn <- 1..4, i <- 1..3 do
        item =
          if turn == 1 and i == 2,
            do: %{
              "id" => "act",
              "type" => "subAgentActivity",
              "agentThreadId" => "child",
              "kind" => "started"
            },
            else: %{"id" => "i#{turn}-#{i}", "type" => "agentMessage", "text" => "x"}

        item_completed(t, item, "turn-#{turn}")
      end
    end

    test "a windowed snapshot: the last `limit` items, what lies above counted (items, whole turns, the cut turn's items) and the sub-agent activities above it listed" do
      t = new_thread()
      twelve_items(t)

      whole = Store.snapshot(t)
      assert length(whole.items) == 12
      assert whole.earlier == %{items: 0, turns: 0, partial: 0, activities: []}

      %{items: items, earlier: earlier} = Store.snapshot(t, limit: 5)
      assert Enum.map(items, & &1["id"]) == ["i3-2", "i3-3", "i4-1", "i4-2", "i4-3"]
      # above: turn-1 and turn-2 whole (7 items with the activity), one item of turn-3
      assert %{items: 7, turns: 2, partial: 1, activities: [%{"id" => "act"}]} = earlier

      assert Store.snapshot(new_thread(), limit: 5).items == []
      assert Store.snapshot(new_thread(), limit: 5).earlier.items == 0
    end

    test "the last turn is never cut: a turn longer than the window comes whole, running or done" do
      t = new_thread()
      for i <- 1..3, do: item_completed(t, %{"id" => "a#{i}", "type" => "agentMessage"}, "turn-1")
      Store.fold(t, "turn/started", %{"turn" => %{"id" => "turn-2", "status" => "inProgress"}})

      for i <- 1..6,
          do: item_started(t, %{"id" => "b#{i}", "type" => "commandExecution"}, "turn-2")

      %{items: items, earlier: earlier} = Store.snapshot(t, limit: 2)
      assert Enum.map(items, & &1["id"]) == Enum.map(1..6, &"b#{&1}")
      assert %{items: 3, turns: 1, partial: 0} = earlier

      Store.fold(t, "turn/completed", %{"turn" => %{"id" => "turn-2", "status" => "completed"}})
      assert length(Store.snapshot(t, limit: 2).items) == 6

      # an item with no turn at the tail (an activity after the turn) belongs with the turn before it
      item_completed(
        t,
        %{"id" => "tail", "type" => "subAgentActivity", "agentThreadId" => "c"},
        nil
      )

      assert length(Store.snapshot(t, limit: 1).items) == 7
    end

    test "earlier/3 pages back from an item, counting what is still above; the last page leaves nothing; an unknown item is refused" do
      t = new_thread()
      twelve_items(t)
      %{items: [%{"id" => first} | _]} = Store.snapshot(t, limit: 3)
      assert first == "i4-1"

      assert {:ok, %{items: page, earlier: earlier}} = Store.earlier(t, first, 4)
      assert Enum.map(page, & &1["id"]) == ["i2-3", "i3-1", "i3-2", "i3-3"]
      # above the page: turn-1 whole, two items of turn-2 (its third is in the page)
      assert %{items: 5, turns: 1, partial: 2, activities: [%{"id" => "act"}]} = earlier

      assert {:ok, %{items: rest, earlier: %{items: 0, turns: 0, partial: 0, activities: []}}} =
               Store.earlier(t, "i2-3", :all)

      assert Enum.map(rest, & &1["id"]) == ["i1-1", "act", "i1-3", "i2-1", "i2-2"]

      assert {:ok, %{items: [], earlier: %{items: 0}}} = Store.earlier(t, "i1-1", 4)
      assert Store.earlier(t, "nope", 4) == {:error, :unknown_item}
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

    test "ingested events are folded, numbered and broadcast in order", %{
      thread_id: thread_id,
      pid: pid
    } do
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

      # A mailbox barrier, not a 100 ms scheduler deadline: all three casts
      # must be folded before checking their exact broadcast sequence.
      :sys.get_state(pid)

      assert_receive {:thread, 1, "turn/started", _}
      assert_receive {:thread, 2, "item/started", _}
      assert_receive {:thread, 3, "item/agentMessage/delta", %{"delta" => "hi"}}

      snapshot = ThreadState.snapshot(thread_id)
      assert snapshot.seq == 3
      assert snapshot.turn["id"] == "turn-1"
      assert [%{"id" => "m1", "text" => "hi"}] = snapshot.items
    end

    test "an event the store cannot fold is logged and skipped; the writer and its seq survive",
         %{thread_id: thread_id, pid: pid} do
      ThreadState.subscribe(thread_id)

      ThreadState.ingest(thread_id, "item/started", %{
        "item" => %{"id" => "m1", "type" => "agentMessage", "text" => 5}
      })

      # appending to a number raises inside Store.fold
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          ThreadState.ingest(thread_id, "item/agentMessage/delta", %{
            "itemId" => "m1",
            "delta" => "hi"
          })

          ThreadState.ingest(thread_id, "item/agentMessage/delta", %{
            "itemId" => "m2",
            "delta" => "ok"
          })

          # generous: under a loaded suite the writer once took more than two seconds
          assert_receive {:thread, 2, "item/agentMessage/delta", %{"itemId" => "m2"}}, 10_000
        end)

      assert log =~ "could not fold item/agentMessage/delta"
      assert Process.alive?(pid)
      refute_received {:thread, _, "item/agentMessage/delta", %{"itemId" => "m1"}}

      assert [%{"id" => "m1", "text" => 5}, %{"id" => "m2", "text" => "ok"}] =
               ThreadState.snapshot(thread_id).items
    end

    test "snapshot reads ETS directly: it works even when the thread process is gone", %{
      thread_id: thread_id
    } do
      # subscribed before the ingest: the writer broadcasts as soon as it folds
      ThreadState.subscribe(thread_id)

      ThreadState.ingest(thread_id, "item/started", %{
        "turnId" => "t",
        "item" => %{"id" => "m1", "type" => "agentMessage", "text" => "kept"}
      })

      assert_receive {:thread, 1, "item/started", _}

      ThreadState.stop(thread_id)
      assert ThreadState.whereis(thread_id) == nil
      assert [%{"text" => "kept"}] = ThreadState.snapshot(thread_id).items
      assert ThreadState.snapshot(thread_id).seq == 1

      # and a restarted process continues the sequence instead of restarting it
      {:ok, _} = ThreadState.ensure(thread_id)

      ThreadState.ingest(thread_id, "item/agentMessage/delta", %{"itemId" => "m1", "delta" => "!"})

      assert_receive {:thread, 2, "item/agentMessage/delta", _}
    end

    test "subscribe-then-snapshot never loses or duplicates events", %{thread_id: thread_id} do
      me = self()

      producer =
        Task.async(fn ->
          for i <- 1..50 do
            ThreadState.ingest(thread_id, "item/agentMessage/delta", %{
              "itemId" => "m",
              "delta" => "#{i},"
            })

            # the page joins mid-stream: once the first deltas are in (a fixed
            # sleep here once lost the race on a loaded machine — no item yet)
            if i == 5, do: send(me, :streaming)
            if rem(i, 10) == 0, do: Process.sleep(5)
          end
        end)

      assert_receive :streaming, 5_000
      ThreadState.subscribe(thread_id)
      snapshot = ThreadState.snapshot(thread_id)
      Task.await(producer)

      live =
        Stream.repeatedly(fn ->
          receive do
            {:thread, seq, _m, %{"delta" => d}} -> {seq, d}
          after
            200 -> nil
          end
        end)
        |> Enum.take_while(&(&1 != nil))

      applied =
        live |> Enum.filter(fn {seq, _} -> seq > snapshot.seq end) |> Enum.map(&elem(&1, 1))

      # `ingest` is a cast: on a loaded machine the page may join before the
      # writer folded the first delta — then the snapshot is empty and every
      # event applies (the join is early, nothing is lost); `[%{"text" => _}] =`
      # once failed the release precommit on exactly that
      text =
        case snapshot.items do
          [%{"text" => text}] -> text
          [] -> ""
        end

      assert text <> Enum.join(applied) == Enum.map_join(1..50, &"#{&1},")

      seqs = Enum.map(live, &elem(&1, 0))
      assert seqs == Enum.to_list(hd(seqs)..List.last(seqs)//1)
    end

    test "server requests show up in the snapshot until resolved", %{thread_id: thread_id} do
      ThreadState.subscribe(thread_id)

      ThreadState.put_request(thread_id, 42, "item/commandExecution/requestApproval", %{
        "command" => "ls"
      })

      assert_receive {:thread, 1, "item/commandExecution/requestApproval",
                      %{"requestId" => 42, "command" => "ls"}}

      assert [%{id: 42}] = ThreadState.snapshot(thread_id).pending_requests

      ThreadState.resolve_request(thread_id, 42)
      assert_receive {:thread, 2, "serverRequest/resolved", %{"requestId" => 42}}
      assert ThreadState.snapshot(thread_id).pending_requests == []
    end

    test "drop_turns/2 removes those turns' items and broadcasts thread/reverted with the ids", %{
      thread_id: thread_id
    } do
      ThreadState.subscribe(thread_id)

      ThreadState.ingest(thread_id, "item/started", %{
        "turnId" => "t1",
        "item" => %{"id" => "a", "type" => "userMessage"}
      })

      ThreadState.ingest(thread_id, "item/started", %{
        "turnId" => "t2",
        "item" => %{"id" => "b", "type" => "userMessage"}
      })

      ThreadState.ingest(thread_id, "item/started", %{
        "turnId" => "t3",
        "item" => %{"id" => "c", "type" => "userMessage"}
      })

      ThreadState.ingest(thread_id, "turn/completed", %{
        "turn" => %{"id" => "t3", "status" => "interrupted"}
      })

      :ok = ThreadState.drop_turns(thread_id, ["t2", "t3"])

      assert_receive {:thread, 5, "thread/reverted",
                      %{"threadId" => ^thread_id, "turnIds" => ["t2", "t3"]}}

      assert Enum.map(ThreadState.snapshot(thread_id).items, & &1["id"]) == ["a"]
      # the current turn was one of them: gone too (a stopped turn discarded
      # once left a ghost "stopped" card at the bottom of the thread)
      assert ThreadState.snapshot(thread_id).turn == nil
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

    test "backfill (a resume on a new codex) withdraws requests the old process was waiting on",
         %{thread_id: thread_id} do
      ThreadState.subscribe(thread_id)
      ThreadState.put_request(thread_id, 7, "item/commandExecution/requestApproval", %{})
      assert_receive {:thread, _, "item/commandExecution/requestApproval", _}

      ThreadState.backfill(thread_id, %{"thread" => %{"id" => thread_id, "turns" => []}})

      assert_receive {:thread, _, "serverRequest/resolved", %{"requestId" => 7}}
      assert ThreadState.snapshot(thread_id).pending_requests == []
    end
  end
end
