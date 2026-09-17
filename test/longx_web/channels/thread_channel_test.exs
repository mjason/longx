defmodule LongxWeb.ThreadChannelTest do
  # The browser's live view of one thread: join → snapshot (with seq), then
  # every ThreadState event as an "event" push (the channel's vocabulary).
  # Joining hosts the thread: its agent is started from the row.
  use LongxWeb.ChannelCase, async: false

  alias Longx.Agent
  alias Longx.Agent.ThreadState
  alias Longx.Projects

  defp join!(thread_id) do
    LongxWeb.UserSocket
    |> socket("user", %{})
    |> subscribe_and_join(LongxWeb.ThreadChannel, "thread:" <> thread_id)
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
