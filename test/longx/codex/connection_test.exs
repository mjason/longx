defmodule Longx.Codex.ConnectionTest do
  use ExUnit.Case, async: false

  alias Longx.Codex.{Connection, Error, ThreadState}

  @fake Path.expand("test/support/fake_app_server.exs")

  # Routes every deferred server request to the test process so tests can
  # answer (or not) explicitly.
  defmodule ForwardingHandler do
    @behaviour Longx.Codex.ServerRequest

    @impl true
    def handle("item/commandExecution/requestApproval" = m, params, ctx) do
      send(:connection_test, {:server_request, m, params, ctx})
      {:defer, 500, {:reply, %{"decision" => "decline"}}}
    end

    def handle("item/tool/call", %{"namespace" => "async", "tool" => "raise"}, _ctx),
      do: {:async, fn -> raise "handler boom" end, 1_000, {:reply, fallback()}}

    def handle("item/tool/call", %{"namespace" => "async", "tool" => "stall"}, _ctx),
      do: {:async, fn -> Process.sleep(10_000) end, 300, {:reply, fallback()}}

    def handle("item/tool/call" = m, params, ctx),
      do: Longx.Codex.ServerRequest.Default.handle(m, params, ctx)

    def handle(m, _params, _ctx), do: {:error, -32601, "#{m} unsupported"}

    defp fallback,
      do: %{
        "success" => false,
        "contentItems" => [%{"type" => "inputText", "text" => "handler fallback"}]
      }
  end

  setup do
    Process.register(self(), :connection_test)
    Phoenix.PubSub.subscribe(Longx.PubSub, "codex:connection")

    conn =
      start_supervised!(
        {Connection,
         name: nil,
         command: ["elixir", @fake],
         env: [],
         server_request_handler: ForwardingHandler,
         request_timeout: 5_000}
      )

    assert_receive {:codex_connection, nil, :ready}, 15_000
    %{conn: conn}
  end

  defp start_thread(conn) do
    {:ok, %{"thread" => %{"id" => thread_id}}} =
      Connection.request(conn, "thread/start", %{"cwd" => "/"})

    ThreadState.subscribe(thread_id)
    thread_id
  end

  defp await_turn_completed(thread_id, timeout \\ 10_000) do
    receive do
      {:codex, _seq, "turn/completed", %{"threadId" => ^thread_id, "turn" => turn}} -> turn
    after
      timeout -> flunk("turn did not complete")
    end
  end

  test "handshake happened (initialize + initialized) and status is ready", %{conn: conn} do
    assert Connection.status(conn) == :ready
  end

  test "request/response pairing and error responses", %{conn: conn} do
    assert {:ok, %{"thread" => %{"id" => "thr_" <> _}}} =
             Connection.request(conn, "thread/start", %{})

    assert {:error, %Error{code: -32601}} = Connection.request(conn, "no/such/method", %{})
  end

  test "notifications are folded into ThreadState with seqs and the turn completes", %{conn: conn} do
    thread_id = start_thread(conn)

    assert {:ok, %{"turn" => %{"id" => turn_id}}} =
             Connection.request(conn, "turn/start", %{
               "threadId" => thread_id,
               "input" => [%{"type" => "text", "text" => "say hello world"}]
             })

    assert %{"status" => "completed", "id" => ^turn_id} = await_turn_completed(thread_id)

    snapshot = ThreadState.snapshot(thread_id)
    assert snapshot.turn["status"] == "completed"
    assert Enum.find(snapshot.items, &(&1["type"] == "agentMessage"))["text"] == "hello world"
    assert snapshot.token_usage == %{"total" => 7}
    assert snapshot.seq > 0
  end

  test "a refreshing client can subscribe → snapshot → continue mid-stream", %{conn: conn} do
    thread_id = start_thread(conn)
    ThreadState.unsubscribe(thread_id)

    {:ok, _} =
      Connection.request(conn, "turn/start", %{
        "threadId" => thread_id,
        "input" => [%{"type" => "text", "text" => "stall"}]
      })

    Process.sleep(200)

    # the "page refresh"
    ThreadState.subscribe(thread_id)
    snapshot = ThreadState.snapshot(thread_id)
    [msg] = Enum.filter(snapshot.items, &(&1["type"] == "agentMessage"))
    assert msg["text"] == "abc"

    :ok = Connection.notify(conn, "fake/continue", %{})
    assert_receive {:codex, seq, "item/agentMessage/delta", %{"delta" => "d"}}, 5_000
    assert seq > snapshot.seq
    await_turn_completed(thread_id)

    assert Enum.find(ThreadState.snapshot(thread_id).items, &(&1["type"] == "agentMessage"))[
             "text"
           ] == "abcd"
  end

  test "server → client requests go to the handler, are pending in ThreadState, and respond/3 answers them",
       %{conn: conn} do
    thread_id = start_thread(conn)

    {:ok, _} =
      Connection.request(conn, "turn/start", %{
        "threadId" => thread_id,
        "input" => [%{"type" => "text", "text" => "approve ls"}]
      })

    assert_receive {:server_request, "item/commandExecution/requestApproval",
                    %{"command" => "ls"}, %{thread_id: ^thread_id}},
                   5_000

    assert_receive {:codex, _, "item/commandExecution/requestApproval",
                    %{"requestId" => request_id, "command" => "ls"}},
                   5_000

    assert [%{id: ^request_id}] = ThreadState.snapshot(thread_id).pending_requests

    assert :ok = Connection.respond(conn, request_id, %{"decision" => "accept"})
    assert_receive {:codex, _, "serverRequest/resolved", %{"requestId" => ^request_id}}, 5_000
    assert ThreadState.snapshot(thread_id).pending_requests == []

    await_turn_completed(thread_id)

    assert Enum.any?(
             ThreadState.snapshot(thread_id).items,
             &(&1["type"] == "commandExecution" and &1["aggregatedOutput"] =~ "ran ls")
           )

    assert {:error, :unknown_request} =
             Connection.respond(conn, request_id, %{"decision" => "accept"})
  end

  test "an unanswered server request gets the handler's fallback after its timeout", %{conn: conn} do
    thread_id = start_thread(conn)

    {:ok, _} =
      Connection.request(conn, "turn/start", %{
        "threadId" => thread_id,
        "input" => [%{"type" => "text", "text" => "approve rm"}]
      })

    assert_receive {:codex, _, "item/commandExecution/requestApproval",
                    %{"requestId" => request_id}},
                   5_000

    # nobody answers; ForwardingHandler's fallback (decline) fires after 500ms
    assert_receive {:codex, _, "serverRequest/resolved", %{"requestId" => ^request_id}}, 5_000
    await_turn_completed(thread_id)

    assert Enum.find(ThreadState.snapshot(thread_id).items, &(&1["type"] == "agentMessage"))[
             "text"
           ] == "declined"
  end

  test "requests time out with {:error, :timeout} and a late answer is ignored", %{conn: conn} do
    thread_id = start_thread(conn)

    assert {:error, :timeout} =
             Connection.request(
               conn,
               "turn/start",
               %{"threadId" => thread_id, "input" => [%{"type" => "text", "text" => "slow 800"}]},
               timeout: 200
             )

    # the fake still answers later; the connection must stay healthy
    Process.sleep(900)
    assert Connection.status(conn) == :ready
    assert {:ok, _} = Connection.request(conn, "thread/start", %{})
  end

  test "notifications without a threadId go to the codex:server topic", %{conn: conn} do
    Phoenix.PubSub.subscribe(Longx.PubSub, "codex:server")
    thread_id = start_thread(conn)

    {:ok, _} =
      Connection.request(conn, "turn/start", %{
        "threadId" => thread_id,
        "input" => [%{"type" => "text", "text" => "server-notify"}]
      })

    # tagged with the connection's tag (the project id in the pool; nil here)
    assert_receive {:codex_server, nil, "account/rateLimits/updated", %{"rateLimits" => _}}, 5_000
  end

  test "a request error is surfaced, not swallowed", %{conn: conn} do
    thread_id = start_thread(conn)

    assert {:error, %Error{code: -32000, message: "fake turn error"}} =
             Connection.request(conn, "turn/start", %{
               "threadId" => thread_id,
               "input" => [%{"type" => "text", "text" => "error"}]
             })
  end

  test "when the connection goes away, the approvals it was waiting on are withdrawn from the thread",
       %{conn: conn} do
    thread_id = start_thread(conn)

    {:ok, _} =
      Connection.request(conn, "turn/start", %{
        "threadId" => thread_id,
        "input" => [%{"type" => "text", "text" => "approve ls"}]
      })

    assert_receive {:codex, _, "item/commandExecution/requestApproval",
                    %{"requestId" => request_id}},
                   5_000

    assert [%{id: ^request_id}] = ThreadState.snapshot(thread_id).pending_requests

    # nobody can answer a request whose codex is gone: it must not linger in the UI
    stop_supervised!(Connection)
    assert_receive {:codex, _, "serverRequest/resolved", %{"requestId" => ^request_id}}, 5_000
    assert ThreadState.snapshot(thread_id).pending_requests == []
  end

  test "when codex dies: pending callers get :connection_reset, :down is broadcast, the process stops",
       %{conn: conn} do
    thread_id = start_thread(conn)
    ref = Process.monitor(conn)

    task =
      Task.async(fn ->
        Connection.request(conn, "turn/start", %{
          "threadId" => thread_id,
          "input" => [%{"type" => "text", "text" => "die"}]
        })
      end)

    assert {:error, :connection_reset} = Task.await(task, 10_000)
    assert_receive {:codex_connection, nil, :down}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^conn, {:shutdown, :codex_exited}}, 5_000
  end

  describe "{:async, ...} server requests (dynamic tool calls)" do
    test "a tool call is executed off the connection process and answered", %{conn: conn} do
      thread_id = start_thread(conn)

      {:ok, _} =
        Connection.request(conn, "turn/start", %{
          "threadId" => thread_id,
          "input" => [%{"type" => "text", "text" => ~s(call test.echo {"message":"hey"})}]
        })

      await_turn_completed(thread_id)

      assert Enum.find(ThreadState.snapshot(thread_id).items, &(&1["type"] == "agentMessage"))[
               "text"
             ] == "tool true: echo: hey"
    end

    test "invalid arguments come back as a failed call the model can read", %{conn: conn} do
      thread_id = start_thread(conn)

      {:ok, _} =
        Connection.request(conn, "turn/start", %{
          "threadId" => thread_id,
          "input" => [%{"type" => "text", "text" => ~s(call test.echo {"message":5})}]
        })

      await_turn_completed(thread_id)

      text =
        Enum.find(ThreadState.snapshot(thread_id).items, &(&1["type"] == "agentMessage"))["text"]

      assert text =~ "tool false:"
      assert text =~ "invalid arguments"
    end

    test "a crashing tool does not take the connection down", %{conn: conn} do
      thread_id = start_thread(conn)

      {:ok, _} =
        Connection.request(conn, "turn/start", %{
          "threadId" => thread_id,
          "input" => [%{"type" => "text", "text" => ~s(call test.boom {})}]
        })

      await_turn_completed(thread_id)

      assert Enum.find(ThreadState.snapshot(thread_id).items, &(&1["type"] == "agentMessage"))[
               "text"
             ] =~ "crashed"

      assert Connection.status(conn) == :ready
    end

    test "a handler fun that itself crashes or stalls falls back", %{conn: conn} do
      thread_id = start_thread(conn)

      # AsyncHandler answers item/tool/call with a fun that raises for "raise" and sleeps for "stall"
      {:ok, _} =
        Connection.request(conn, "turn/start", %{
          "threadId" => thread_id,
          "input" => [%{"type" => "text", "text" => ~s(call async.raise {})}]
        })

      await_turn_completed(thread_id)

      assert Enum.find(ThreadState.snapshot(thread_id).items, &(&1["type"] == "agentMessage"))[
               "text"
             ] == "tool false: handler fallback"

      thread_id = start_thread(conn)

      {:ok, _} =
        Connection.request(conn, "turn/start", %{
          "threadId" => thread_id,
          "input" => [%{"type" => "text", "text" => ~s(call async.stall {})}]
        })

      await_turn_completed(thread_id)

      assert Enum.find(ThreadState.snapshot(thread_id).items, &(&1["type"] == "agentMessage"))[
               "text"
             ] == "tool false: handler fallback"

      assert Connection.status(conn) == :ready
    end
  end

  test "requests made before the handshake completes are queued, not rejected" do
    conn =
      start_supervised!({Connection, name: nil, command: ["elixir", @fake], env: [], id: :second},
        id: :second
      )

    # fire immediately; elixir takes a moment to boot the fake
    assert {:ok, %{"thread" => _}} =
             Connection.request(conn, "thread/start", %{}, timeout: 15_000)
  end
end
