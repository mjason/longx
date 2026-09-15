defmodule Longx.Codex.SandboxPassthroughIntegrationTest do
  @moduledoc """
  The bwrap wrapper against the real binary: a host path a project lets in
  (`passthrough:` on `Home.prepare/1`) is visible to a sandboxed command,
  and stays hidden without it. Needs a device to look at: WSL2's `/dev/dxg`
  or an nvidia node — skipped where the machine has neither.
  """
  use Longx.DataCase, async: false

  import Longx.Test.CodexHarness

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

  # the model: first call → run `ls -la <device>` through codex's shell tool
  # (whatever it is called in this build), then report what came back
  defp script_model(bypass, device, test_pid) do
    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      outputs = for %{"type" => "function_call_output", "output" => out} <- body["input"], do: out
      send(test_pid, {:outputs, outputs})

      if outputs == [] do
        names = for %{"type" => "function", "name" => n} <- body["tools"], do: n
        shell = Enum.find(names, &(&1 in ["exec_command", "shell", "shell_command"]))
        assert shell, "no shell tool among #{inspect(names)}"

        args =
          if shell == "shell",
            do: %{command: ["ls", "-la", device]},
            else: %{cmd: "ls -la #{device}", yield_time_ms: 10_000}

        send_sse(conn, ResponsesFixture.function_call(shell, nil, args))
      else
        send_sse(conn, ResponsesFixture.assistant_message("done"))
      end
    end)
  end

  defp flush_outputs do
    receive do
      {:outputs, _} -> flush_outputs()
    after
      0 -> :ok
    end
  end

  defp device do
    Enum.find(["/dev/dxg", "/dev/nvidiactl", "/dev/nvidia0"], &File.exists?/1)
  end

  test "a device the project lets in is there for the sandboxed command; without the passthrough it is not",
       %{bypass: bypass, gateway_url: gateway_url} do
    device = device()

    if device do
      test_pid = self()
      script_model(bypass, device, test_pid)

      for {passthrough, expect} <- [{[device], :present}, {[], :absent}] do
        # the previous run's model calls are still in the mailbox
        flush_outputs()
        home = prepare_home!(gateway_url, passthrough: passthrough)
        conn = start_connection!(home)
        thread_id = start_thread!(conn, home, sandbox: :workspace_write)
        {turn, _items} = run_turn!(conn, thread_id, "look at the device")
        assert turn["status"] == "completed", inspect(turn)

        assert_receive {:outputs, [output]}, 10_000
        text = if is_binary(output), do: output, else: inspect(output)

        # `ls -la` of a character device starts its line with `c`; hidden → "No such file"
        case expect do
          :present -> assert text =~ ~r/^c[rwx-]{9}.*#{Regex.escape(device)}$/m, text
          :absent -> assert text =~ "No such file", text
        end
      end
    else
      IO.puts("no GPU device on this machine — passthrough integration test skipped")
    end
  end
end
