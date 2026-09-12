defmodule LongxWeb.ThreadChannelTest do
  # The browser's live view of one codex thread: join → snapshot (with seq),
  # then every ThreadState event as a "codex" push. Fake app-server.
  use LongxWeb.ChannelCase, async: false

  alias Longx.Codex.{Connection, Thread}

  @fake Path.expand("test/support/fake_app_server.exs")

  defp join!(thread_id) do
    LongxWeb.UserSocket
    |> socket("user", %{})
    |> subscribe_and_join(LongxWeb.ThreadChannel, "thread:" <> thread_id)
  end

  setup do
    conn = start_supervised!({Connection, name: nil, command: ["elixir", @fake], env: []})
    {:ok, thread_id} = Thread.start(cwd: "/", tools: [], conn: conn)
    {:ok, _, socket} = join!(thread_id)
    %{conn: conn, thread_id: thread_id, socket: socket}
  end

  test "join replies with the current snapshot", %{socket: socket, thread_id: thread_id} do
    {:ok, reply, _} = join!(thread_id)
    assert %{seq: seq, items: items, thread: thread} = reply
    assert is_integer(seq)
    assert is_list(items)
    assert thread["id"] == thread_id
    assert socket.assigns.thread_id == thread_id
  end

  test "events stream as `codex` pushes carrying seq/method/params", %{
    conn: conn,
    thread_id: thread_id
  } do
    {:ok, _turn_id} = Thread.send(thread_id, "say hi", conn: conn)

    assert_push "codex", %{seq: s1, method: "turn/started", params: %{"threadId" => ^thread_id}}

    assert_push "codex",
                %{seq: s2, method: "item/agentMessage/delta", params: %{"delta" => _}},
                5_000

    assert_push "codex", %{seq: s3, method: "turn/completed", params: _}, 5_000
    assert s1 < s2 and s2 < s3
  end

  test "`snapshot` can be asked for again (a client catching up after a gap)", %{
    socket: socket,
    thread_id: thread_id
  } do
    ref = push(socket, "snapshot", %{})
    assert_reply ref, :ok, %{seq: _, thread: %{"id" => ^thread_id}}
  end

  test "joining an unknown thread is refused" do
    assert {:error, %{reason: "unknown thread"}} = join!("thr_nobody")
  end
end
