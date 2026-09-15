defmodule Longx.Codex.SandboxDenialIntegrationTest do
  @moduledoc """
  A command the sandbox denies, against the real binary: with Longx's
  on-request policy (codex's granular one) codex asks the person to retry
  outside the sandbox — the approval card — and an accept reruns it there.
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

  test "denied inside the sandbox → 'retry without sandbox?' → accept → runs outside and reports",
       %{
         bypass: bypass,
         gateway_url: gateway_url
       } do
    test_pid = self()
    # the home is read-only inside the sandbox and writable outside: a denial that an
    # unsandboxed retry turns into a real file
    probe =
      Path.join(System.user_home!(), "longx-denial-probe-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm(probe) end)

    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      outputs = for %{"type" => "function_call_output", "output" => o} <- body["input"], do: o
      send(test_pid, {:outputs, outputs})

      if outputs == [] do
        send_sse(
          conn,
          ResponsesFixture.function_call("exec_command", nil, %{
            cmd: "touch #{probe} && echo written"
          })
        )
      else
        send_sse(conn, ResponsesFixture.assistant_message("done"))
      end
    end)

    home = prepare_home!(gateway_url)
    conn = start_connection!(home)
    # the harness starts threads with approval never; this is what Projects passes for on_request
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
    assert request["reason"] =~ "retry without sandbox"
    assert request["command"] =~ "touch #{probe}"
    # it is in the snapshot as a pending request (the UI's approval card)
    assert Enum.any?(
             ThreadState.snapshot(thread_id).pending_requests,
             &(&1.id == request["requestId"])
           )

    :ok = Thread.respond(request["requestId"], :accept, thread_id: thread_id)
    assert_receive {:codex, _, "turn/completed", _}, 60_000

    # the retry ran outside the sandbox: the file exists and the model saw "written"
    assert File.regular?(probe)
    assert_receive {:outputs, [output]}, 5_000
    assert output =~ "written"
    refute output =~ "Read-only file system"

    types = Enum.map(Thread.snapshot(thread_id).items, & &1["type"])
    IO.puts("items after the retry: #{inspect(types)}")
  end
end
