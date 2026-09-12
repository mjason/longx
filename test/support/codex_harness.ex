defmodule Longx.Test.CodexHarness do
  @moduledoc """
  Helpers for tests that drive the real bundled codex-app-server through
  `Longx.Codex.Connection` / `Longx.Codex.Thread`: serve the real endpoint on
  a loopback port, prepare a throwaway CODEX_HOME, start a connection, and
  wait for a turn while collecting what it produced.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias Longx.Codex.{Connection, Home, Runtime, Thread}

  @doc "Starts Bandit on the real endpoint; returns the gateway URL codex should use."
  def serve_endpoint! do
    {:ok, bandit} =
      start_supervised(
        {Bandit, plug: LongxWeb.Endpoint, scheme: :http, ip: {127, 0, 0, 1}, port: 0}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    "http://127.0.0.1:#{port}/ai/v1"
  end

  @doc "A fresh CODEX_HOME under ./data (codex refuses tmp dirs), removed after the test."
  def prepare_home!(gateway_url, opts \\ []) do
    dir = Path.join(Path.expand("data"), "codex_home_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, home} = Home.prepare([dir: dir, gateway_url: gateway_url] ++ opts)
    home
  end

  @doc "Starts an (unnamed) connection to the bundled binary with `home`'s env and waits for the handshake."
  def start_connection!(home) do
    {:ok, exe} = Runtime.executable()
    Phoenix.PubSub.subscribe(Longx.PubSub, "codex:connection")

    conn =
      start_supervised!(
        {Connection,
         name: nil, command: [exe], env: home.env, cd: home.dir, id: {:conn, home.dir}},
        id: {:conn, home.dir}
      )

    assert_receive {:codex_connection, :ready}, 30_000
    conn
  end

  @doc "Starts a thread (never asks for approvals, read-only sandbox) and subscribes the caller."
  def start_thread!(conn, home) do
    {:ok, thread_id} =
      Thread.start(cwd: home.dir, approval_policy: :never, sandbox: :read_only, conn: conn)

    :ok = Thread.subscribe(thread_id)
    thread_id
  end

  @doc """
  Sends `text` and waits for `turn/completed`. Returns `{turn, items}` where
  `items` are the completed items seen during the turn, in order.
  """
  def run_turn!(conn, thread_id, text, timeout \\ 90_000) do
    {:ok, turn_id} = Thread.send(thread_id, text, conn: conn)
    collect(turn_id, [], System.monotonic_time(:millisecond) + timeout)
  end

  defp collect(turn_id, items, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:codex, _seq, "turn/completed", %{"turn" => %{"id" => ^turn_id} = turn}} ->
        {turn, Enum.reverse(items)}

      {:codex, _seq, "item/completed", %{"item" => item}} ->
        if System.get_env("CODEX_DEBUG"),
          do:
            IO.puts(
              "item/completed #{item["type"]} #{inspect(Map.take(item, ["text", "command"]))}"
            )

        collect(turn_id, [item | items], deadline)

      {:codex, _seq, "error", %{"error" => error}} ->
        IO.puts("codex error: #{inspect(error["message"])}")
        collect(turn_id, items, deadline)

      {:codex, _seq, _method, _params} ->
        collect(turn_id, items, deadline)
    after
      remaining ->
        flunk("turn #{turn_id} did not complete in time; items so far: #{inspect(items)}")
    end
  end

  def agent_messages(items),
    do: for(%{"type" => "agentMessage", "text" => text} <- items, do: text)
end
