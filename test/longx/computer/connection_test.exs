defmodule Longx.Computer.ConnectionTest do
  use Longx.DataCase, async: false

  alias Longx.Computer.{Connection, MCP, Pool, Service}
  alias Longx.Agent.{Context, Step}
  alias Longx.Agent.Plugs.Computer

  @token "test-only-bearer-01234567890123456789"

  setup do
    Connection.disconnect()
    bypass = Bypass.open()
    {:ok, log} = Agent.start_link(fn -> [] end)
    endpoint = %{url: "http://127.0.0.1:#{bypass.port}/mcp", port: bypass.port, token: @token}
    previous = Application.get_env(:longx, Longx.Computer, [])
    Application.put_env(:longx, Longx.Computer, Keyword.put(previous, :endpoint, endpoint))

    Bypass.stub(bypass, "DELETE", "/mcp", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer " <> @token]
      Plug.Conn.resp(conn, 204, "")
    end)

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer " <> @token]
      assert Plug.Conn.get_req_header(conn, "origin") == []
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      Agent.update(log, &[request | &1])
      response = reply(request)

      conn
      |> Plug.Conn.put_resp_header("mcp-session-id", "fixture-http-session")
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => response})
      )
    end)

    on_exit(fn ->
      Connection.disconnect()
      Application.put_env(:longx, Longx.Computer, previous)
    end)

    %{bypass: bypass, log: log, endpoint: endpoint}
  end

  test "connect is asynchronous, discovers curated tools and exposes no credential", %{log: log} do
    connect()
    assert %{phase: "ready", foreground: false, tool_count: 5} = Connection.status()
    refute Jason.encode!(Connection.status()) =~ @token
    methods = Agent.get(log, &Enum.map(&1, fn request -> request["method"] end))
    assert "initialize" in methods
    assert "tools/list" in methods
    refute Enum.any?(Connection.catalog(), &(&1["name"] == "stop"))
  end

  test "one turn owns the desktop, fresh observation required before input; cleanup releases it",
       %{log: log} do
    connect()
    owner = {"thread", "turn"}
    assert {:error, message} = Connection.call(owner, "click", %{})
    assert message =~ "observe"
    assert {:ok, _} = Connection.call(owner, "get_window_state", %{"pid" => 1, "window_id" => 2})
    assert {:error, message} = Connection.call({"other", "turn"}, "list_apps", %{})
    assert message =~ "another"

    assert {:ok, _} =
             Connection.call(owner, "click", %{
               "target" => %{"kind" => "window", "pid" => 1, "window_id" => 2},
               "element_token" => "fresh"
             })

    calls = Agent.get(log, & &1)
    click = Enum.find(calls, &(get_in(&1, ["params", "name"]) == "click"))
    assert get_in(click, ["params", "arguments", "session"]) == "longx-thread-turn"
    Connection.release(owner)
    eventually(fn -> not Connection.status().busy end)
    assert Enum.any?(Agent.get(log, & &1), &(get_in(&1, ["params", "name"]) == "end_session"))
  end

  test "foreground and full-display scope cannot silently escalate" do
    connect()
    owner = {"thread", "turn"}

    for {tool, args} <- [
          {"get_desktop_state", %{}},
          {"click", %{"delivery_mode" => "foreground"}},
          {"click", %{"target" => %{"kind" => "desktop", "display_id" => "primary"}}}
        ] do
      assert {:error, message} = Connection.call(owner, tool, args)
      assert message =~ "not enabled"
    end
  end

  test "actual turn completion releases the desktop even without a turn-end plug", %{log: log} do
    connect()
    owner = {"finished-thread", "finished-turn"}
    assert {:ok, _} = Connection.call(owner, "get_window_state", %{})

    Phoenix.PubSub.broadcast(
      Longx.PubSub,
      "thread:finished-thread",
      {:thread, 1, "turn/completed",
       %{"threadId" => "finished-thread", "turn" => %{"id" => "finished-turn"}}}
    )

    eventually(fn -> not Connection.status().busy end)
    assert Enum.any?(Agent.get(log, & &1), &(get_in(&1, ["params", "name"]) == "end_session"))
    assert Connection.status().phase == "ready"
    assert {:ok, _} = Connection.call({"next-thread", "next-turn"}, "list_apps", %{})
  end

  test "an explicit HTTP session survives a TCP reconnect",
       %{endpoint: endpoint, log: log} do
    connect()
    owner = {"thread", "turn"}
    assert {:ok, _} = Connection.call(owner, "get_window_state", %{})
    :ok = Finch.stop_pool(Longx.Computer.Finch, endpoint.url)
    assert {:ok, _} = Connection.call(owner, "click", %{"element_token" => "fresh"})
    assert Enum.any?(Agent.get(log, & &1), &(get_in(&1, ["params", "name"]) == "click"))
    assert Connection.status().phase == "ready"
  end

  test "a service generation loss prevents input and the heartbeat invalidates stale ready state",
       %{bypass: bypass, log: log} do
    connect()
    owner = {"thread", "turn"}
    assert {:ok, _} = Connection.call(owner, "get_window_state", %{})
    Bypass.stub(bypass, "POST", "/mcp", fn conn -> Plug.Conn.resp(conn, 404, "") end)
    assert {:error, _} = Connection.call(owner, "click", %{"element_token" => "stale"})
    refute Enum.any?(Agent.get(log, & &1), &(get_in(&1, ["params", "name"]) == "click"))
    assert Connection.status().phase == "disconnected"
  end

  test "an agent exiting between calls releases its desktop lease" do
    connect()
    test = self()

    pid =
      spawn(fn ->
        {:ok, _} = Registry.register(Longx.Agent.Registry, "computer-test-agent", nil)
        send(test, :agent_registered)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :agent_registered
    assert {:ok, _} = Connection.call({"computer-test-agent", "turn"}, "get_window_state", %{})
    assert Connection.status().busy
    send(pid, :stop)
    eventually(fn -> not Connection.status().busy end)
    assert Connection.status().phase == "ready"
  end

  test "a refused session cleanup invalidates the connection", %{bypass: bypass} do
    connect()
    owner = {"thread", "turn"}
    assert {:ok, _} = Connection.call(owner, "get_window_state", %{})

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      result =
        if get_in(request, ["params", "name"]) == "end_session",
          do: %{"isError" => true},
          else: reply(request)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => result})
      )
    end)

    Connection.release(owner)
    eventually(fn -> Connection.status().phase == "disconnected" end)
    refute Connection.status().busy
    assert Connection.status().error =~ "cleaned up"
  end

  test "cancelling a caller disconnects the transport and rejects queued control",
       %{bypass: bypass} do
    connect()
    test = self()

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      if get_in(request, ["params", "name"]) == "get_window_state" do
        send(test, {:pending, self()})

        receive do
          :finish -> :ok
        after
          5_000 -> :ok
        end
      end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => reply(request)})
      )
    end)

    task =
      Task.Supervisor.async_nolink(Longx.Computer.TaskSupervisor, fn ->
        Connection.call({"thread", "turn"}, "get_window_state", %{})
      end)

    assert_receive {:pending, handler}, 2_000
    # Closing the client is the behaviour under test. Cowboy may terminate its
    # blocked handler with :shutdown; don't treat that expected abort as a
    # failed mock-server response.
    Bypass.pass(bypass)
    Task.shutdown(task, :brutal_kill)
    eventually(fn -> Connection.status().phase == "disconnected" end)
    assert Connection.status().error =~ "interrupted"
    send(handler, :finish)
  end

  test "HTTP authentication failure is not retried and a bearer is never returned",
       %{bypass: bypass, endpoint: endpoint} do
    Bypass.expect_once(bypass, "POST", "/mcp", fn conn ->
      Plug.Conn.resp(conn, 401, "")
    end)

    assert {:error, {:http, 401}} = MCP.request(endpoint, "ping")
  end

  test "a service cannot echo its bearer into a model-facing result", %{
    bypass: bypass,
    endpoint: endpoint
  } do
    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "id" => request["id"],
          "result" => %{"text" => @token}
        })
      )
    end)

    assert {:ok, %{"text" => "[redacted]"}} = MCP.request(endpoint, "ping")
  end

  test "Computer mounts discovered schemas, strips transport/path fields and leaves the default pipeline alone" do
    connect()
    step = Computer.call(Step.new(thread_id: "t", turn_id: "u"), [])
    assert Map.has_key?(step.tools, "computer_get_window_state")
    schema = step.tools["computer_get_window_state"].schema
    refute Map.has_key?(schema["properties"], "session")
    refute Map.has_key?(schema["properties"], "screenshot_out_file")
    refute List.keymember?(Longx.Agent.Pipelines.Default.plugs(), Computer, 0)
    assert Longx.Agent.Config.builtin(Elixir.Computer) == Computer
  end

  test "images and structured tokens/effects survive the tool result; MCP errors stay errors" do
    result = %{
      "content" => [
        %{"type" => "image", "mimeType" => "image/png", "data" => "aW1hZ2U="},
        %{"type" => "text", "text" => "observed"}
      ],
      "structuredContent" => %{"element_token" => "opaque", "effect" => "unverifiable"}
    }

    assert {:ok, text, meta} = Computer.format(result, "get_window_state", %Context{})
    assert text =~ "opaque"
    assert text =~ "unverifiable"
    assert meta["images"] == ["data:image/png;base64,aW1hZ2U="]
    assert {:error, _, _} = Computer.format(Map.put(result, "isError", true), "click", %Context{})
  end

  test "two computers have independent leases, permissions and interruption boundaries", %{
    log: local_log
  } do
    %{id: id, log: other_log} = second_computer()
    connect()
    assert {:ok, _} = Connection.connect(id, true)
    eventually(fn -> Connection.status(id).phase == "ready" end)
    assert {:ok, _} = Connection.call({"local-owner", "turn"}, "get_window_state", %{})
    assert {:ok, _} = Connection.call(id, {"remote-owner", "turn"}, "get_window_state", %{})
    assert Connection.status().busy
    assert Connection.status(id).busy
    assert {:error, _} = Connection.call(id, {"local-owner", "turn"}, "click", %{})
    assert {:ok, _} = Connection.call(id, {"remote-owner", "turn"}, "get_desktop_state", %{})
    assert {:error, _} = Connection.call({"local-owner", "turn"}, "get_desktop_state", %{})
    assert :ok = Connection.disconnect()
    assert Connection.status(id).phase == "ready"
    assert {:ok, _} = Connection.call(id, {"remote-owner", "turn"}, "click", %{})
    refute Enum.any?(Agent.get(local_log, & &1), &(get_in(&1, ["params", "name"]) == "click"))
    assert Enum.any?(Agent.get(other_log, & &1), &(get_in(&1, ["params", "name"]) == "click"))
  end

  test "aliases bind per turn; disconnect, alias edits and reconnect never reroute old tools" do
    %{id: id} = second_computer()
    connect()
    assert {:ok, _} = Connection.connect(id, false)
    eventually(fn -> Connection.status(id).phase == "ready" end)
    assert :ok = Service.put_alias("qa", [id, "local"])
    owner = {"multi-binding-thread", "multi-binding-turn"}
    assert {:ok, ^id} = Pool.resolve(owner, "qa")

    step =
      Computer.call(Step.new(thread_id: elem(owner, 0), turn_id: elem(owner, 1)), computer: "qa")

    tool = step.tools["computer_click"]
    context = %Context{thread_id: elem(owner, 0), turn_id: elem(owner, 1)}
    assert :ok = Service.put_alias("qa", ["local", id])
    assert {:ok, ^id} = Pool.resolve(owner, "qa")
    assert :ok = Connection.disconnect(id)
    assert {:error, _} = Pool.resolve(owner, "qa")
    assert {:ok, "local"} = Pool.resolve({"new-binding-thread", "new-turn"}, "qa")
    assert {:ok, _} = Connection.connect(id, false)
    eventually(fn -> Connection.status(id).phase == "ready" end)
    assert {:error, message} = tool.fun.(%{}, context)
    assert message =~ "changed"
    assert {:error, _} = Pool.resolve(owner, "qa")
    complete(owner)
    eventually(fn -> Pool.resolve(owner, "qa") == {:ok, "local"} end)
    complete(owner)
    complete({"new-binding-thread", "new-turn"})
  end

  defp complete({thread, turn}) do
    Phoenix.PubSub.broadcast(
      Longx.PubSub,
      "thread:#{thread}",
      {:thread, 1, "turn/completed", %{"threadId" => thread, "turn" => %{"id" => turn}}}
    )
  end

  defp second_computer do
    bypass = Bypass.open()
    id = "other-#{System.unique_integer([:positive])}"
    {:ok, log} = Agent.start_link(fn -> [] end)
    url = "http://127.0.0.1:#{bypass.port}/mcp"
    assert {:ok, _} = Service.save(id, "Other", url, @token)
    Bypass.stub(bypass, "DELETE", "/mcp", &Plug.Conn.resp(&1, 204, ""))

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer " <> @token]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      Agent.update(log, &[request | &1])

      conn
      |> Plug.Conn.put_resp_header("mcp-session-id", "other-session")
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"id" => request["id"], "result" => reply(request)}))
    end)

    on_exit(fn -> Connection.stop(id) end)
    %{id: id, log: log}
  end

  test "a slow request on one computer does not serialize another computer", %{bypass: bypass} do
    %{id: id} = second_computer()
    connect()
    assert {:ok, _} = Connection.connect(id, false)
    eventually(fn -> Connection.status(id).phase == "ready" end)
    parent = self()

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      if get_in(request, ["params", "name"]) == "get_window_state" do
        send(parent, {:blocked_local, self()})

        receive do
          :finish -> :ok
        after
          5_000 -> :ok
        end
      end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"id" => request["id"], "result" => reply(request)}))
    end)

    task = Task.async(fn -> Connection.call({"slow-local", "turn"}, "get_window_state", %{}) end)
    assert_receive {:blocked_local, handler}, 2_000
    assert {:ok, _} = Connection.call(id, {"fast-other", "turn"}, "get_window_state", %{})
    assert Process.alive?(task.pid)
    send(handler, :finish)
    assert {:ok, _} = Task.await(task)
  end

  test "unknown ids do not create persistent connection processes" do
    id = "unknown-#{System.unique_integer([:positive])}"
    assert %{phase: "disconnected", error: "Unknown computer"} = Connection.status(id)
    assert {:error, "Unknown computer"} = Connection.connect(id, false)
    assert Registry.lookup(Longx.Computer.Registry, id) == []
  end

  defp connect do
    assert {:ok, %{phase: "connecting"}} = Connection.connect()
    eventually(fn -> Connection.status().phase == "ready" end)
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end

  defp reply(%{"method" => "initialize"}), do: %{"protocolVersion" => "2025-06-18"}

  defp reply(%{"method" => "tools/list"}) do
    %{
      "tools" =>
        for name <- ~w(list_apps get_window_state get_desktop_state click launch_app stop) do
          %{
            "name" => name,
            "description" => "test tool",
            "inputSchema" => %{
              "type" => "object",
              "properties" => %{
                "session" => %{"type" => "string"},
                "screenshot_out_file" => %{"type" => "string"}
              },
              "required" => [],
              "additionalProperties" => false
            }
          }
        end
    }
  end

  defp reply(%{"method" => "tools/call"}),
    do: %{"content" => [], "structuredContent" => %{"ok" => true}}

  defp reply(_), do: %{}
end
