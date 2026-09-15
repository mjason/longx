defmodule Longx.Codex.SandboxPermissionsIntegrationTest do
  @moduledoc """
  codex's own permission requests against the real binary, the way the
  chat answers them: a command that asks for a directory
  (`with_additional_permissions`) becomes an approval carrying
  `additionalPermissions` — accepted, it runs *inside* the sandbox with that
  one directory writable; the `request_permissions` tool becomes a
  permissions request answered with a turn- or session-scoped grant.
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

  # a thread the way Projects starts one: workspace-write, on-request
  defp on_request_thread!(conn, home) do
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
    thread_id
  end

  defp script(bypass, test_pid, first_call) do
    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      outputs = for %{"type" => "function_call_output", "output" => o} <- body["input"], do: o
      send(test_pid, {:outputs, outputs})

      if outputs == [],
        do: send_sse(conn, first_call.(body)),
        else: send_sse(conn, ResponsesFixture.assistant_message("done"))
    end)
  end

  test "a command asking for a directory: the approval carries the permissions; accepted, it runs sandboxed with that directory writable",
       %{bypass: bypass, gateway_url: gateway_url} do
    test_pid = self()
    # the home is read-only in the sandbox — the one directory the command asks for
    probe =
      Path.join(System.user_home!(), "longx-perm-probe-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm(probe) end)

    script(bypass, test_pid, fn body ->
      names = for t <- body["tools"], do: t["name"]

      assert "request_permissions" in names,
             "request_permissions tool not offered: #{inspect(names)}"

      shell = Enum.find(body["tools"], &(&1["name"] == "exec_command"))
      assert Map.has_key?(shell["parameters"]["properties"], "additional_permissions")

      ResponsesFixture.function_call("exec_command", nil, %{
        cmd: "touch #{probe} && echo written",
        sandbox_permissions: "with_additional_permissions",
        additional_permissions: %{file_system: %{write: [Path.dirname(probe)]}},
        justification: "write a probe file in the home"
      })
    end)

    home = prepare_home!(gateway_url)
    conn = start_connection!(home)
    thread_id = on_request_thread!(conn, home)
    {:ok, _} = Thread.send(thread_id, "go", conn: conn)

    assert_receive {:codex, _, "item/commandExecution/requestApproval", request}, 30_000
    assert request["reason"] == "write a probe file in the home"
    assert %{"fileSystem" => %{"write" => [dir]}} = request["additionalPermissions"]
    assert dir == Path.dirname(probe)
    assert request["availableDecisions"] == ["accept", "cancel"]
    # the pending request is in the snapshot for the approval card
    assert Enum.any?(
             ThreadState.snapshot(thread_id).pending_requests,
             &(&1.id == request["requestId"])
           )

    :ok = Thread.respond(request["requestId"], :accept, thread_id: thread_id)
    assert_receive {:codex, _, "turn/completed", _}, 60_000

    # ran inside the sandbox with the directory writable: the file exists, the item is reported
    assert File.regular?(probe)
    assert_receive {:outputs, [output]}, 5_000
    assert output =~ "written"
    assert Enum.any?(Thread.snapshot(thread_id).items, &(&1["type"] == "commandExecution"))
  end

  test "the request_permissions tool: a permissions request, granted for the turn or the session, refused with nothing",
       %{bypass: bypass, gateway_url: gateway_url} do
    test_pid = self()
    home = prepare_home!(gateway_url)
    conn = start_connection!(home)

    script(bypass, test_pid, fn _body ->
      ResponsesFixture.function_call("request_permissions", nil, %{
        permissions: %{file_system: %{write: [System.user_home!()]}, network: %{enabled: true}},
        reason: "install into the home and fetch a package"
      })
    end)

    for {decision, scope, granted?} <- [
          {:accept, "turn", true},
          {:accept_for_session, "session", true},
          {:decline, "turn", false}
        ] do
      thread_id = on_request_thread!(conn, home)
      {:ok, _} = Thread.send(thread_id, "go", conn: conn)

      assert_receive {:codex, _, "item/permissions/requestApproval", request}, 30_000
      assert request["reason"] == "install into the home and fetch a package"

      assert %{"fileSystem" => %{"write" => [_]}, "network" => %{"enabled" => true}} =
               request["permissions"]

      :ok = Thread.respond(request["requestId"], decision, thread_id: thread_id)
      assert_receive {:codex, _, "turn/completed", _}, 60_000

      # what the model was told it got
      assert_receive {:outputs, [output]}, 5_000
      granted = Jason.decode!(output)
      assert granted["scope"] == scope

      if granted?,
        do: assert(granted["permissions"]["network"]["enabled"] == true),
        else:
          assert(granted["permissions"] in [%{}, nil, %{"network" => nil, "file_system" => nil}])
    end
  end
end
