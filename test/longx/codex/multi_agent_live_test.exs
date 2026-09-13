defmodule Longx.Codex.MultiAgentLiveTest do
  @moduledoc """
  What sub-agents look like on the wire: the real codex + DeepSeek, a
  thread with `multi_agent: true`, one turn that spawns helpers. Prints the
  notifications so the data model can be checked against reality.
  Needs DEEPSEEK_API_KEY.
  """
  use Longx.DataCase, async: false
  import Longx.Test.CodexHarness

  alias Longx.AI
  alias Longx.Codex.ThreadState

  @moduletag :live
  @moduletag timeout: 300_000

  setup do
    key = System.get_env("DEEPSEEK_API_KEY") || flunk("DEEPSEEK_API_KEY not set")
    Ash.bulk_destroy!(AI.Model, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(AI.Provider, :destroy, %{}, authorize?: false)

    provider =
      AI.create_provider!(%{
        name: "DeepSeek",
        slug: "deepseek",
        base_url: "https://api.deepseek.com/v1",
        api_key: key
      })

    AI.create_model!(%{
      name: "DeepSeek Flash",
      upstream_id: "deepseek-flash",
      provider_id: provider.id
    })
    |> AI.make_default_model!()

    dump = Path.expand("data/multi_agent_live_requests")
    File.rm_rf!(dump)
    Application.put_env(:longx, Longx.AI.Gateway, dump_requests_to: dump)
    on_exit(fn -> Application.delete_env(:longx, Longx.AI.Gateway) end)
    %{gateway_url: serve_endpoint!()}
  end

  test "spawning two sub-agents: items, child threads, activity", %{gateway_url: gateway_url} do
    home = prepare_home!(gateway_url)
    File.write!(Path.join(home.dir, "a.txt"), "alpha\n")
    File.write!(Path.join(home.dir, "b.txt"), "beta\n")
    conn = start_connection!(home)
    Phoenix.PubSub.subscribe(Longx.PubSub, "codex:server")
    thread_id = start_thread!(conn, home, multi_agent: true)

    {:ok, turn_id} =
      Longx.Codex.Thread.send(
        thread_id,
        "Use the collaboration tools: spawn two sub-agents in parallel — one reads a.txt and reports its content, the other reads b.txt and reports its content. Wait for both, then reply with both contents on one line.",
        conn: conn
      )

    log = collect(turn_id, [], System.monotonic_time(:millisecond) + 240_000)
    IO.puts("\n===== #{length(log)} notifications")

    for {method, params} <- log do
      case method do
        "thread/started" ->
          t = params["thread"]

          IO.puts(
            "thread/started id=#{t["id"]} parent=#{inspect(t["parentThreadId"])} nick=#{inspect(t["agentNickname"])} role=#{inspect(t["agentRole"])} source=#{inspect(t["source"])}"
          )

        m when m in ["item/started", "item/completed"] ->
          it = params["item"]

          extra =
            Map.drop(it, ["type", "id"])
            |> Map.take([
              "tool",
              "status",
              "agentsStates",
              "receiverThreadIds",
              "senderThreadId",
              "prompt",
              "kind",
              "agentPath",
              "agentThreadId",
              "text",
              "command",
              "model"
            ])

          IO.puts(
            "#{m} thread=#{String.slice(params["threadId"] || "?", 0, 8)} #{it["type"]} #{inspect(extra, limit: :infinity, printable_limit: 200)}"
          )

        m
        when m in [
               "turn/started",
               "turn/completed",
               "turn/plan/updated",
               "thread/status/changed",
               "thread/name/updated",
               "thread/closed"
             ] ->
          IO.puts(
            "#{m} thread=#{String.slice(params["threadId"] || get_in(params, ["thread", "id"]) || "?", 0, 8)} #{inspect(Map.take(params, ["plan", "explanation", "status", "name"]), limit: :infinity)}"
          )

        _ ->
          :ok
      end
    end

    child_ids =
      for {m, %{"item" => %{"type" => "subAgentActivity", "agentThreadId" => id}}} <- log,
          m == "item/completed",
          uniq: true,
          do: id

    IO.puts("children: #{inspect(child_ids)}")

    IO.puts(
      "parent item types: #{inspect(for {"item/completed", %{"item" => it}} <- log, do: it["type"])}"
    )

    IO.puts("parent status: #{inspect(ThreadState.snapshot(thread_id).status)}")

    for child <- child_ids do
      snap = ThreadState.snapshot(child)

      IO.puts(
        "child #{String.slice(child, 0, 8)} thread meta: #{inspect(snap.thread && Map.take(snap.thread, ["id", "parentThreadId", "agentNickname", "agentRole", "name", "source"]))}"
      )

      IO.puts(
        "child #{String.slice(child, 0, 8)} turn: #{inspect(snap.turn && Map.take(snap.turn, ["id", "status"]))} status: #{inspect(snap.status)}"
      )

      IO.puts(
        "child #{String.slice(child, 0, 8)}: #{length(snap.items)} items, types #{inspect(Enum.map(snap.items, & &1["type"]))}"
      )

      for it <- snap.items,
          it["type"] in ["userMessage", "agentMessage"],
          do:
            IO.puts(
              "   #{it["type"]}: #{inspect(it["text"] || it["content"], printable_limit: 300)}"
            )
    end

    # keep codex's log for inspection
    File.cp!(
      Path.join(home.dir, "logs_2.sqlite"),
      Path.expand("data/multi_agent_live_logs.sqlite")
    )

    assert child_ids != []
  end

  # every notification on the parent's topic + codex:server + any child topic we learn about
  defp collect(turn_id, log, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:codex, _seq, "turn/completed", %{"turn" => %{"id" => ^turn_id}} = params} ->
        Enum.reverse([{"turn/completed", params} | log])

      {:codex, _seq, method, params} ->
        if method == "thread/started", do: Longx.Codex.Thread.subscribe(params["thread"]["id"])
        collect(turn_id, [{method, params} | log], deadline)

      {:codex, method, params} ->
        if method == "thread/started", do: Longx.Codex.Thread.subscribe(params["thread"]["id"])
        collect(turn_id, [{method, params} | log], deadline)
    after
      remaining -> flunk("turn did not complete; log so far: #{length(log)}")
    end
  end
end
