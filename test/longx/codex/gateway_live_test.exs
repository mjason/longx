defmodule Longx.Codex.GatewayLiveTest do
  @moduledoc """
  Bundled codex → our gateway → the real DeepSeek `deepseek-flash`.
  Needs DEEPSEEK_API_KEY and network; `mix test --include live`.
  """
  use Longx.DataCase, async: false

  alias Longx.AI
  alias Longx.Codex.Home
  alias Longx.Test.CodexClient

  @moduletag :live
  @moduletag timeout: 180_000

  setup do
    key = System.get_env("DEEPSEEK_API_KEY") || flunk("DEEPSEEK_API_KEY not set")

    Ash.bulk_destroy!(AI.Model, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(AI.Provider, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(AI.SearchProvider, :destroy, %{}, authorize?: false)

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

    {:ok, bandit} =
      start_supervised(
        {Bandit, plug: LongxWeb.Endpoint, scheme: :http, ip: {127, 0, 0, 1}, port: 0}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)

    home_dir =
      Path.join(Path.expand("data"), "codex_home_live_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(home_dir) end)
    {:ok, home} = Home.prepare(dir: home_dir, gateway_url: "http://127.0.0.1:#{port}/ai/v1")

    %{home: home}
  end

  test "a real DeepSeek turn completes end to end", %{home: home} do
    {shim, thread_id} = CodexClient.start_thread(home)

    turn =
      CodexClient.run_turn(shim, thread_id, "Reply with exactly the word PONG and nothing else.")

    assert turn["status"] == "completed", "turn did not complete: #{inspect(turn)}"
    assert_received {:agent_message, text}
    assert text =~ "PONG"

    CodexClient.stop(shim)
  end

  test "DeepSeek drives a tool call (exec_command) through codex", %{home: home} do
    # Something the model cannot guess, so it has to run a command.
    secret = "LONGX-" <> Base.encode16(:crypto.strong_rand_bytes(6))
    File.write!(Path.join(home.dir, "secret.txt"), secret <> "\n")

    {shim, thread_id} = CodexClient.start_thread(home)

    turn =
      CodexClient.run_turn(
        shim,
        thread_id,
        "Read the file secret.txt in the current working directory with a shell command and reply with its exact contents."
      )

    assert turn["status"] == "completed", "turn did not complete: #{inspect(turn)}"

    assert_received {:command_execution, item}
    assert item["status"] == "completed"
    assert item["aggregatedOutput"] =~ secret

    # the model may send a preamble before the tool call; the answer is the last message
    messages = collect_agent_messages()
    assert List.last(messages) =~ secret, "no agent message with the secret: #{inspect(messages)}"

    # nothing else was called: no hallucinated web search / mcp tools
    refute_received {:item_completed, "mcpToolCall", _}
    refute_received {:item_completed, "webSearch", _}

    CodexClient.stop(shim)
  end

  test "DeepSeek searches the web through Tavily via our /alpha/search", %{home: home} do
    tavily_key = System.get_env("TAVILY_API_KEY") || flunk("TAVILY_API_KEY not set")

    AI.create_search_provider!(%{
      name: "Tavily",
      slug: "tavily",
      kind: :tavily,
      api_key: tavily_key
    })
    |> AI.make_default_search_provider!()

    {:ok, home} =
      Home.prepare(dir: home.dir, gateway_url: gateway_url_of(home), web_search: :standalone)

    {shim, thread_id} = CodexClient.start_thread(home)

    turn =
      CodexClient.run_turn(
        shim,
        thread_id,
        "Search the web: what is the latest stable release version of the Elixir programming language right now? Cite the source URL.",
        150_000
      )

    assert turn["status"] == "completed", "turn did not complete: #{inspect(turn)}"
    assert_received {:item_completed, "webSearch", _}

    # the model does not always inline a URL; the search item above is the proof it browsed
    messages = collect_agent_messages()
    assert List.last(messages) =~ ~r/\d+\.\d+/, "no version number in: #{inspect(messages)}"

    CodexClient.stop(shim)
  end

  defp gateway_url_of(home) do
    home.config_path
    |> File.read!()
    |> then(&Regex.run(~r/base_url = "([^"]+)"/, &1))
    |> Enum.at(1)
  end

  defp collect_agent_messages(acc \\ []) do
    receive do
      {:agent_message, text} -> collect_agent_messages([text | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
