defmodule Longx.Exec.ExecServerIntegrationTest do
  @moduledoc """
  The real bundled codex-app-server running its commands through Longx's
  exec-server (`environments.toml` → `LongxWeb.ExecSocket`): the command's
  output reaches the model; the sandbox is Longx's own — the cwd writable,
  the rest not, no network but local sockets alive; a project's passthrough
  devices are visible from the next command on.
  """
  use Longx.DataCase, async: false

  import Longx.Test.CodexHarness

  alias Longx.Codex.{Connection, Thread, ThreadState}
  alias Longx.Test.ResponsesFixture

  @moduletag :integration

  setup do
    Ash.bulk_destroy!(Longx.AI.Model, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(Longx.AI.Provider, :destroy, %{}, authorize?: false)
    bypass = Bypass.open()

    {:ok, provider} =
      Longx.AI.create_provider(%{
        name: "Fake",
        slug: "fake",
        base_url: "http://localhost:#{bypass.port}/v1",
        api_key: "k"
      })

    {:ok, model} =
      Longx.AI.create_model(%{
        name: "Fake",
        upstream_id: "fake-model",
        provider_id: provider.id,
        context_window: 128_000
      })

    {:ok, _} = Longx.AI.make_default_model(model)
    %{bypass: bypass, gateway_url: serve_endpoint!()}
  end

  defp send_sse(conn, frames) do
    conn =
      conn |> Plug.Conn.put_resp_content_type("text/event-stream") |> Plug.Conn.send_chunked(200)

    Enum.reduce(frames, conn, fn frame, conn ->
      {:ok, conn} = Plug.Conn.chunk(conn, frame)
      conn
    end)
  end

  # the model: one command, then "done"; every tool output is sent to the test
  defp script(bypass, test_pid, args) do
    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      outputs = for %{"type" => "function_call_output", "output" => o} <- body["input"], do: o
      send(test_pid, {:outputs, outputs})

      if outputs == [],
        do:
          send_sse(
            conn,
            ResponsesFixture.function_call(
              "exec_command",
              nil,
              Map.merge(%{yield_time_ms: 15_000}, args)
            )
          ),
        else: send_sse(conn, ResponsesFixture.assistant_message("done"))
    end)
  end

  defp run!(conn, home, opts) do
    params =
      Thread.start_params(
        Keyword.merge(
          [cwd: home.dir, sandbox: :workspace_write, approval_policy: :never, tools: []],
          opts
        )
      )

    {:ok, %{"thread" => %{"id" => thread_id}}} = Connection.request(conn, "thread/start", params)
    {:ok, _} = ThreadState.ensure(thread_id)
    :ok = Thread.subscribe(thread_id)
    {:ok, _} = Thread.send(thread_id, "go", conn: conn)
    assert_receive {:codex, _, "turn/completed", _}, 90_000
    assert_receive {:outputs, [output]}, 5_000
    output
  end

  test "a command runs through the exec-server inside Longx's sandbox: the cwd writable, the home not, its output back to the model",
       %{bypass: bypass, gateway_url: gateway_url} do
    probe =
      Path.join(System.user_home!(), "longx-exec-probe-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm(probe) end)

    script(bypass, self(), %{
      cmd: "touch here && echo made-here && (touch #{probe} 2>&1; echo rc=$?)"
    })

    home = prepare_home!(gateway_url, exec_server_url: exec_server_url!(gateway_url))
    conn = start_connection!(home)
    output = run!(conn, home, [])

    assert output =~ "made-here"
    assert output =~ "Read-only file system"
    assert output =~ "rc=1"
    assert File.exists?(Path.join(home.dir, "here"))
    refute File.exists?(probe)
  end

  test "no network means no network — a local socket still answers (CUDA's driver socket, a daemon)",
       %{bypass: bypass, gateway_url: gateway_url} do
    sock = Path.join(System.tmp_dir!(), "longx-exec-#{System.unique_integer([:positive])}.sock")
    {:ok, listen} = :gen_tcp.listen(0, [:binary, ifaddr: {:local, sock}, active: false])
    on_exit(fn -> File.rm(sock) end)

    Task.start_link(fn ->
      {:ok, client} = :gen_tcp.accept(listen)
      :gen_tcp.send(client, "hello from the host\n")
      :gen_tcp.close(client)
    end)

    {:ok, tcp} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, port} = :inet.port(tcp)

    script(bypass, self(), %{
      cmd:
        "python3 -c \"import socket; s=socket.socket(socket.AF_UNIX); s.connect('#{sock}'); print('unix:', s.recv(64).decode().strip())\"; " <>
          "python3 -c \"import socket; s=socket.socket(); s.settimeout(2); s.connect(('127.0.0.1', #{port}))\" 2>&1 | tail -1"
    })

    home = prepare_home!(gateway_url, exec_server_url: exec_server_url!(gateway_url))
    conn = start_connection!(home)
    output = run!(conn, home, [])

    assert output =~ "unix: hello from the host"
    assert output =~ ~r/Network is unreachable|Connection refused|timed out/
  end

  test "tty: codex's exec_command on a terminal — the command sees a tty", %{
    bypass: bypass,
    gateway_url: gateway_url
  } do
    script(bypass, self(), %{
      cmd: "python3 -c 'import sys; print(\"isatty\", sys.stdout.isatty(), sys.stdin.isatty())'",
      tty: true
    })

    home = prepare_home!(gateway_url, exec_server_url: exec_server_url!(gateway_url))
    conn = start_connection!(home)
    assert run!(conn, home, []) =~ "isatty True True"
  end

  # codex's on-demand permissions widen *our* sandbox: a directory granted
  # for one command (`with_additional_permissions`) or for the turn
  # (`request_permissions`) is writable in the command that follows
  test "a permission the person grants — per command or per turn — reaches the sandbox of the next command",
       %{bypass: bypass, gateway_url: gateway_url} do
    test_pid = self()

    probe =
      Path.join(System.user_home!(), "longx-exec-grant-#{System.unique_integer([:positive])}")

    File.mkdir_p!(probe)
    on_exit(fn -> File.rm_rf!(probe) end)

    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      outputs = for %{"type" => "function_call_output", "output" => o} <- body["input"], do: o
      send(test_pid, {:outputs, outputs})

      case outputs do
        [] ->
          send_sse(
            conn,
            ResponsesFixture.function_call("exec_command", nil, %{
              cmd: "touch #{probe}/per-command && echo ok-command",
              sandbox_permissions: "with_additional_permissions",
              additional_permissions: %{file_system: %{read: [probe], write: [probe]}},
              justification: "write a probe file"
            })
          )

        [_] ->
          send_sse(
            conn,
            ResponsesFixture.function_call("request_permissions", nil, %{
              permissions: %{file_system: %{read: [probe], write: [probe]}},
              reason: "the rest of the turn writes there"
            })
          )

        [_, _] ->
          send_sse(
            conn,
            ResponsesFixture.function_call("exec_command", nil, %{
              cmd: "touch #{probe}/per-turn && echo ok-turn"
            })
          )

        _ ->
          send_sse(conn, ResponsesFixture.assistant_message("done"))
      end
    end)

    home = prepare_home!(gateway_url, exec_server_url: exec_server_url!(gateway_url))
    conn = start_connection!(home)

    params =
      Thread.start_params(
        cwd: home.dir,
        sandbox: :workspace_write,
        approval_policy: :on_request,
        tools: []
      )

    {:ok, %{"thread" => %{"id" => thread_id}}} = Connection.request(conn, "thread/start", params)
    {:ok, _} = ThreadState.ensure(thread_id)
    :ok = Thread.subscribe(thread_id)
    {:ok, _} = Thread.send(thread_id, "go", conn: conn)

    assert_receive {:codex, _, "item/commandExecution/requestApproval", request}, 30_000
    :ok = Thread.respond(request["requestId"], :accept, thread_id: thread_id)
    assert_receive {:codex, _, "item/permissions/requestApproval", request}, 60_000
    :ok = Thread.respond(request["requestId"], :accept, thread_id: thread_id)
    assert_receive {:codex, _, "turn/completed", _}, 90_000

    assert_receive {:outputs, [first, _grant, second]}, 5_000
    assert first =~ "ok-command", first
    assert second =~ "ok-turn", second
    assert File.exists?(Path.join(probe, "per-command"))
    assert File.exists?(Path.join(probe, "per-turn"))
  end

  test "a project's passthrough paths reach a sandboxed command from the next command on, no restart",
       %{bypass: bypass, gateway_url: gateway_url} do
    # a host path outside the workspace is read-only in the sandbox until the
    # project lets it in (a device, a socket, or — here — a plain file)
    probe = Path.join(System.user_home!(), "longx-exec-pt-#{System.unique_integer([:positive])}")
    File.write!(probe, "")
    on_exit(fn -> File.rm(probe) end)

    dir = Path.join(Path.expand("data"), "exec_project_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, project} = Longx.Projects.create_project(%{name: "exec", root_path: dir})

    script(bypass, self(), %{cmd: "(echo x > #{probe} && echo written) 2>&1"})
    home = prepare_home!(gateway_url, exec_server_url: exec_server_url!(gateway_url, project.id))
    conn = start_connection!(home)

    assert run!(conn, home, []) =~ ~r/read-only file system/i

    {:ok, _} = Longx.Projects.update_project(project, %{passthrough_paths: [probe]})
    assert run!(conn, home, []) =~ "written"
    assert File.read!(probe) == "x\n"
  end
end
