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
    # the fake's thread/started may still be on its way under a loaded suite:
    # the snapshot is re-pulled until the view carries the thread
    assert %{seq: _, thread: %{"id" => ^thread_id}} = snapshot_with_thread(socket, 20)
  end

  defp snapshot_with_thread(socket, tries) do
    ref = push(socket, "snapshot", %{})
    assert_reply ref, :ok, payload, 2_000

    case payload do
      %{thread: %{"id" => _}} -> payload
      _ when tries > 1 -> snapshot_with_thread(socket, tries - 1)
      _ -> payload
    end
  end

  test "joining an unknown thread is refused" do
    assert {:error, %{reason: "unknown thread"}} = join!("thr_nobody")
  end

  describe "a project thread nobody hosts (codex stopped, page opened)" do
    setup do
      Ash.bulk_destroy!(Longx.Projects.Thread, :destroy, %{}, authorize?: false)
      Ash.bulk_destroy!(Longx.Projects.Project, :destroy, %{}, authorize?: false)
      dir = Path.join(System.tmp_dir!(), "longx-chan-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      project = Longx.Projects.create_project!(%{name: "Chan", root_path: dir})
      {:ok, thread} = Longx.Projects.start_thread(project)
      :ok = Longx.Codex.Pool.stop(project.id, force: true)

      on_exit(fn ->
        Longx.Test.PoolHelpers.stop_pool!([project.id])
        File.rm_rf!(dir)
      end)

      %{project: project, thread: thread}
    end

    test "join resumes it on the project's codex and answers with its snapshot", %{
      thread: thread,
      project: project
    } do
      assert {:error, :no_connection} =
               Longx.Codex.Pool.connection_for_thread(thread.codex_thread_id)

      assert {:ok, %{thread_id: id, seq: _}, _socket} = join!(thread.codex_thread_id)
      assert id == thread.codex_thread_id
      assert {:ok, _} = Longx.Codex.Pool.connection_for_thread(thread.codex_thread_id)
      assert Longx.Codex.Pool.status(project.id) != :stopped
    end

    test "an empty thread codex cannot resume is started afresh under a new codex id", %{
      project: project
    } do
      # codex only writes a thread to disk on its first turn; after a restart
      # an empty one cannot be resumed — nothing is lost by starting it again
      {:ok, thread} =
        Longx.Projects.create_thread(%{
          codex_thread_id: "thr_vanished",
          project_id: project.id,
          cwd: project.root_path,
          approval_policy: :on_request,
          sandbox: :workspace_write,
          tools: []
        })

      assert {:ok, %{thread_id: new_id}, _socket} = join!("thr_vanished")
      assert new_id != "thr_vanished"

      assert %{codex_thread_id: ^new_id, status: :idle} =
               Ash.get!(Longx.Projects.Thread, thread.id)

      assert {:ok, _} = Longx.Codex.Pool.connection_for_thread(new_id)
    end

    test "an unrecoverable thread still joins (read-only) instead of erroring", %{
      thread: thread
    } do
      Longx.Projects.touch_thread!(thread, %{status: :unrecoverable})
      assert {:ok, %{thread_id: id}, _socket} = join!(thread.codex_thread_id)
      assert id == thread.codex_thread_id
    end
  end
end
