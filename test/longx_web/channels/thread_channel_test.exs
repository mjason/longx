defmodule LongxWeb.ThreadChannelTest do
  # The browser's live view of one thread: join → snapshot (with seq), then
  # every ThreadState event as an "event" push (the channel's vocabulary).
  # Joining hosts the thread: its agent is started from the row.
  use LongxWeb.ChannelCase, async: false

  alias Longx.Agent
  alias Longx.Agent.ThreadState
  alias Longx.Projects

  defp join!(thread_id, payload \\ %{}) do
    LongxWeb.UserSocket
    |> socket("user", %{})
    |> subscribe_and_join(LongxWeb.ThreadChannel, "thread:" <> thread_id, payload)
  end

  defp message!(thread_id, id, turn) do
    :ok =
      ThreadState.ingest(thread_id, "item/completed", %{
        "threadId" => thread_id,
        "turnId" => turn,
        "item" => %{"id" => id, "type" => "agentMessage", "text" => id}
      })
  end

  setup do
    Ash.bulk_destroy!(Projects.Thread, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(Projects.Project, :destroy, %{}, authorize?: false)
    dir = Path.join(System.tmp_dir!(), "longx-chan-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    project = Projects.create_project!(%{name: "Chan", root_path: dir})
    {:ok, thread} = Projects.start_thread(project)
    id = thread.kernel_thread_id

    on_exit(fn ->
      Longx.Test.Agents.stop_all!()
      File.rm_rf!(dir)
    end)

    %{project: project, thread: thread, thread_id: id}
  end

  test "join replies with the current snapshot", %{thread_id: thread_id} do
    {:ok, reply, socket} = join!(thread_id)
    assert %{seq: seq, items: [], thread_id: ^thread_id} = reply
    assert is_integer(seq)
    assert socket.assigns.thread_id == thread_id
  end

  test "an archived thread restores paged history after the view is lost without reviving its agent",
       %{thread: thread, thread_id: id} do
    for {item_id, turn_id, seq} <- [{"a", "turn_a", 1}, {"b", "turn_b", 2}] do
      :ok =
        Longx.Agent.Transcript.append!(%{
          thread_id: id,
          turn_id: turn_id,
          seq: seq,
          kind: :agent_message,
          input: %{"type" => "message", "role" => "assistant", "content" => []},
          ui: %{"id" => item_id, "type" => "agentMessage", "text" => "kept #{item_id}"}
        })
    end

    Projects.archive_thread!(thread)
    Agent.stop(id)
    Longx.Agent.Kernel.Specs.delete(id)
    ThreadState.stop(id)
    ThreadState.Store.delete(id)

    assert ThreadState.snapshot(id).items == []
    {:ok, reply, socket} = join!(id, %{"limit" => 1})
    assert [%{"id" => "b", "text" => "kept b"}] = reply.items
    assert reply.earlier.items == 1
    assert reply.turn["status"] == "completed"
    assert reply.thread["status"] == "archived"
    assert Agent.whereis(id) == nil
    assert Longx.Agent.Kernel.Specs.get(id) == nil
    assert Projects.get_thread_by_kernel_id!(id).status == :archived

    ref = push(socket, "earlier", %{"before" => "b", "limit" => "all"})
    assert_reply ref, :ok, %{items: [%{"id" => "a", "text" => "kept a"}]}, 2_000
    # A second join neither duplicates history nor registers a runnable agent.
    {:ok, again, _} = join!(id, %{"limit" => "all"})
    assert length(again.items) == 2
    assert Agent.whereis(id) == nil
    assert length(Longx.Agent.Transcript.items!(id)) == 2
  end

  test "a poisoned item (a term JSON cannot take) neither refuses the join nor kills the push: the payloads are cleaned",
       %{thread_id: thread_id} do
    # straight into the store, past the folds' own scrub: the worst the view can hold
    :ok =
      ThreadState.ingest(thread_id, "item/completed", %{
        "threadId" => thread_id,
        "turnId" => "turn_1",
        "item" => %{
          "id" => "bad",
          "type" => "agentMessage",
          "text" => "x",
          "extra" => {:tuple, self()}
        }
      })

    {:ok, reply, _socket} = join!(thread_id)
    assert {:ok, _} = Jason.encode(reply)
    assert [%{"id" => "bad", "extra" => extra}] = reply.items
    assert is_binary(extra) and extra =~ "tuple"

    :ok =
      ThreadState.ingest(thread_id, "item/agentMessage/delta", %{
        "threadId" => thread_id,
        "itemId" => "bad",
        "delta" => "more",
        "oops" => make_ref()
      })

    assert_push "event", %{method: "item/agentMessage/delta", params: params}
    assert {:ok, _} = Jason.encode(params)
  end

  test "events stream as `codex` pushes carrying seq/method/params", %{thread_id: thread_id} do
    {:ok, _, _socket} = join!(thread_id)

    :ok = ThreadState.ingest(thread_id, "turn/started", event(thread_id, "turn_1"))

    :ok =
      ThreadState.ingest(thread_id, "item/agentMessage/delta", %{
        "threadId" => thread_id,
        "itemId" => "m1",
        "delta" => "hi"
      })

    :ok = ThreadState.ingest(thread_id, "turn/completed", event(thread_id, "turn_1"))

    assert_push "event", %{seq: s1, method: "turn/started", params: %{"threadId" => ^thread_id}}
    assert_push "event", %{seq: s2, method: "item/agentMessage/delta", params: %{"delta" => "hi"}}
    assert_push "event", %{seq: s3, method: "turn/completed", params: _}
    assert s1 < s2 and s2 < s3
  end

  test "`snapshot` can be asked for again (a client catching up after a gap)", %{
    thread_id: thread_id
  } do
    {:ok, _, socket} = join!(thread_id)
    :ok = ThreadState.ingest(thread_id, "turn/started", event(thread_id, "turn_1"))
    assert_push "event", %{method: "turn/started"}
    ref = push(socket, "snapshot", %{})
    assert_reply ref, :ok, %{seq: seq, turn: %{"id" => "turn_1"}}, 2_000
    assert seq >= 1
  end

  defp event(thread_id, turn_id),
    do: %{"threadId" => thread_id, "turn" => %{"id" => turn_id, "status" => "inProgress"}}

  test "a join names its window: the last that many items come (the last turn whole), what is above is counted; `earlier` pages up, `snapshot` takes a limit too",
       %{thread_id: thread_id} do
    # the writes are casts: wait for every one to be in the store before the join reads it
    :ok = ThreadState.subscribe(thread_id)
    for id <- ~w(a1 a2 a3), do: message!(thread_id, id, "turn_1")
    for id <- ~w(b1 b2), do: message!(thread_id, id, "turn_2")
    for _ <- 1..5, do: assert_receive({:thread, _, "item/completed", _})

    {:ok, reply, socket} = join!(thread_id, %{"limit" => 1})
    assert Enum.map(reply.items, & &1["id"]) == ["b1", "b2"]
    assert %{items: 3, turns: 1, partial: 0, activities: []} = reply.earlier

    ref = push(socket, "earlier", %{"before" => "b1", "limit" => 2})
    assert_reply ref, :ok, %{items: page, earlier: %{items: 1, turns: 0, partial: 1}}, 2_000
    assert Enum.map(page, & &1["id"]) == ["a2", "a3"]

    ref = push(socket, "earlier", %{"before" => "a2", "limit" => "all"})
    assert_reply ref, :ok, %{items: [%{"id" => "a1"}], earlier: %{items: 0}}, 2_000

    ref = push(socket, "snapshot", %{"limit" => "all"})
    assert_reply ref, :ok, %{items: [_, _, _, _, _], earlier: %{items: 0}}, 2_000

    # a join with no window gets the default (the tail; here everything)
    {:ok, whole, _socket} = join!(thread_id)
    assert length(whole.items) == 5
  end

  test "`earlier` before an item the store no longer has is refused (the client re-snapshots)",
       %{thread_id: thread_id} do
    {:ok, _, socket} = join!(thread_id)
    ref = push(socket, "earlier", %{"before" => "gone", "limit" => 10})
    assert_reply ref, :error, %{reason: "unknown item"}, 2_000
  end

  test "joining an unknown thread is refused" do
    assert {:error, %{reason: "unknown thread"}} = join!("native_nobody")
  end

  test "join after a restart starts the agent again from the row", %{thread_id: thread_id} do
    :ok = Agent.stop(thread_id)
    refute Agent.whereis(thread_id)
    assert {:ok, %{thread_id: ^thread_id}, _socket} = join!(thread_id)
    assert Agent.whereis(thread_id)
  end

  test "an unrecoverable thread still joins (read-only) instead of erroring", %{
    thread: thread,
    thread_id: thread_id
  } do
    :ok = Agent.stop(thread_id)
    Projects.touch_thread!(thread, %{status: :unrecoverable})
    assert {:ok, %{thread_id: ^thread_id}, _socket} = join!(thread_id)
    refute Agent.whereis(thread_id)
  end
end
