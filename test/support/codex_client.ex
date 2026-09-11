defmodule Longx.Test.CodexClient do
  @moduledoc """
  Throwaway newline-delimited JSON-RPC client over `Longx.Shim` for driving the
  bundled codex-app-server in tests, until `Longx.Codex.Connection` exists.
  Agent messages seen while waiting are sent to the caller as
  `{:agent_message, text}`.
  """

  import ExUnit.Assertions

  alias Longx.Codex.Runtime
  alias Longx.Shim

  def start_thread(home, opts \\ []) do
    {:ok, exe} = Runtime.executable()
    {:ok, shim} = Shim.start_link([exe], env: home.env, cd: home.dir)

    send_rpc(shim, %{
      id: 0,
      method: "initialize",
      params: %{clientInfo: %{name: "longx-test", version: "0.0.0"}}
    })

    %{"id" => 0, "result" => _} = await(shim, &match?(%{"id" => 0}, &1))
    send_rpc(shim, %{method: "initialized", params: %{}})

    params =
      Map.merge(%{cwd: home.dir, approvalPolicy: "never", sandbox: "read-only"}, Map.new(opts))

    send_rpc(shim, %{id: 1, method: "thread/start", params: params})

    %{"result" => %{"thread" => %{"id" => thread_id}}} = await(shim, &match?(%{"id" => 1}, &1))
    {shim, thread_id}
  end

  def run_turn(shim, thread_id, text, timeout \\ 90_000) do
    send_rpc(shim, %{
      id: 2,
      method: "turn/start",
      params: %{threadId: thread_id, input: [%{type: "text", text: text}]}
    })

    %{"method" => "turn/completed", "params" => %{"turn" => turn}} =
      await(shim, &match?(%{"method" => "turn/completed"}, &1), timeout)

    turn
  end

  def stop(shim) do
    :ok = Shim.kill(shim, 2_000)
    {:ok, _} = Shim.await_exit(shim, 5_000)
  end

  def send_rpc(shim, msg), do: :ok = Shim.write(shim, [Jason.encode!(msg), "\n"])

  def await(shim, pred, timeout \\ 30_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await(shim, pred, deadline)
  end

  defp do_await(shim, pred, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining <= 0, do: flunk("timed out waiting for codex message")

    {:ok, chunk} = Shim.read(shim, 65_531, remaining)
    buffer = Process.get(:codex_client_buffer, "") <> chunk
    {lines, rest} = split_lines(buffer)
    Process.put(:codex_client_buffer, rest)

    messages = Enum.map(lines, &Jason.decode!/1)

    if System.get_env("CODEX_CLIENT_DEBUG"),
      do: Enum.each(messages, &IO.puts("codex <- " <> summarize(&1)))

    Enum.each(messages, &record/1)

    case Enum.find(messages, pred) do
      nil -> do_await(shim, pred, deadline)
      found -> found
    end
  end

  defp summarize(%{"method" => m, "params" => %{"item" => %{"type" => t} = item}}),
    do: "#{m} item=#{t} #{inspect(Map.take(item, ["status", "command", "id"]))}"

  defp summarize(%{"method" => m, "params" => %{"turn" => %{"status" => s}}}),
    do: "#{m} turn=#{s}"

  defp summarize(%{"method" => m}), do: m

  defp summarize(%{"id" => id} = msg),
    do: "response id=#{id} #{if msg["error"], do: inspect(msg["error"]), else: "ok"}"

  defp split_lines(buffer) do
    {complete, [rest]} = buffer |> String.split("\n") |> Enum.split(-1)
    {Enum.reject(complete, &(&1 == "")), rest}
  end

  defp record(%{
         "method" => "item/completed",
         "params" => %{"item" => %{"type" => "agentMessage", "text" => text}}
       }),
       do: send(self(), {:agent_message, text})

  defp record(%{
         "method" => "item/completed",
         "params" => %{"item" => %{"type" => "commandExecution"} = item}
       }),
       do: send(self(), {:command_execution, item})

  defp record(%{"method" => "item/completed", "params" => %{"item" => %{"type" => type} = item}}),
    do: send(self(), {:item_completed, type, item})

  defp record(%{"method" => "error", "params" => params}),
    do: IO.puts("codex error: #{inspect(params)}")

  defp record(_), do: :ok
end
