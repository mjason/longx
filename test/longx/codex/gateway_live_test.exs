defmodule Longx.Codex.GatewayLiveTest do
  @moduledoc """
  Bundled codex → Longx.Codex.Connection → our gateway → the real DeepSeek
  `deepseek-flash` (and real Tavily). Needs DEEPSEEK_API_KEY / TAVILY_API_KEY
  and network; `mix test --include live`.
  """
  use Longx.DataCase, async: false

  import Longx.Test.CodexHarness

  alias Longx.AI

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

    %{gateway_url: serve_endpoint!()}
  end

  test "a real DeepSeek turn completes end to end", %{gateway_url: gateway_url} do
    home = prepare_home!(gateway_url)
    conn = start_connection!(home)
    thread_id = start_thread!(conn, home)

    {turn, items} =
      run_turn!(conn, thread_id, "Reply with exactly the word PONG and nothing else.")

    assert turn["status"] == "completed", inspect(turn)
    assert List.last(agent_messages(items)) =~ "PONG"
  end

  test "DeepSeek drives a tool call (exec_command) through codex", %{gateway_url: gateway_url} do
    home = prepare_home!(gateway_url)
    secret = "LONGX-" <> Base.encode16(:crypto.strong_rand_bytes(6))
    File.write!(Path.join(home.dir, "secret.txt"), secret <> "\n")

    conn = start_connection!(home)
    thread_id = start_thread!(conn, home)

    {turn, items} =
      run_turn!(
        conn,
        thread_id,
        "Read the file secret.txt in the current working directory with a shell command and reply with its exact contents."
      )

    assert turn["status"] == "completed", inspect(turn)

    assert Enum.any?(
             items,
             &(&1["type"] == "commandExecution" and &1["status"] == "completed" and
                 (&1["aggregatedOutput"] || "") =~ secret)
           )

    assert List.last(agent_messages(items)) =~ secret
    refute Enum.any?(items, &(&1["type"] in ["mcpToolCall", "webSearch"]))
  end

  test "DeepSeek searches the web through Tavily via our /alpha/search", %{
    gateway_url: gateway_url
  } do
    tavily_key = System.get_env("TAVILY_API_KEY") || flunk("TAVILY_API_KEY not set")

    AI.create_search_provider!(%{
      name: "Tavily",
      slug: "tavily",
      kind: :tavily,
      api_key: tavily_key
    })
    |> AI.make_default_search_provider!()

    assert AI.web_search_mode() == :standalone

    home = prepare_home!(gateway_url)
    conn = start_connection!(home)
    thread_id = start_thread!(conn, home)

    {turn, items} =
      run_turn!(
        conn,
        thread_id,
        "Search the web: what is the latest stable release version of the Elixir programming language right now? Cite the source URL.",
        150_000
      )

    assert turn["status"] == "completed", inspect(turn)
    assert Enum.any?(items, &(&1["type"] == "webSearch"))
    # the model does not always inline a URL; the search item above is the proof it browsed
    assert List.last(agent_messages(items)) =~ ~r/\d+\.\d+/
  end
end
