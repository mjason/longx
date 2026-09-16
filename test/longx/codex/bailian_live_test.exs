defmodule Longx.Codex.BailianLiveTest do
  @moduledoc """
  Bundled codex → our gateway → the real 阿里云百炼 Token Plan endpoint
  (`compatible-mode/v1`, Responses API): a plain turn, a tool call, and the
  model's own web search (the standard `web_search` tool, hosted). Needs
  `BAILIAN_TOKEN_PLAN_API_KEY` and network; `mix test --include live`.
  """
  use Longx.DataCase, async: false

  import Longx.Test.CodexHarness

  alias Longx.AI

  @moduletag :live
  @moduletag timeout: 240_000

  @base_url "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"

  setup do
    key =
      System.get_env("BAILIAN_TOKEN_PLAN_API_KEY") || flunk("BAILIAN_TOKEN_PLAN_API_KEY not set")

    Ash.bulk_destroy!(AI.Model, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(AI.Provider, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(AI.SearchProvider, :destroy, %{}, authorize?: false)

    provider =
      AI.create_provider!(%{
        name: "阿里云百炼 Token Plan",
        slug: "bailian-token-plan",
        base_url: @base_url,
        api_key: key,
        supports_hosted_web_search: true
      })

    AI.create_model!(%{
      name: "qwen3.8-max",
      upstream_id: "qwen3.8-max",
      slug: "qwen3.8-max",
      provider_id: provider.id,
      context_window: 983_616,
      reasoning_levels: ~w(low medium xhigh),
      reasoning_effort: "low"
    })
    |> AI.make_default_model!()

    %{gateway_url: serve_endpoint!()}
  end

  test "a real Token Plan turn completes end to end (reasoning effort, parallel_tool_calls and all)",
       %{gateway_url: gateway_url} do
    home = prepare_home!(gateway_url)
    conn = start_connection!(home)
    thread_id = start_thread!(conn, home)

    {turn, items} =
      run_turn!(conn, thread_id, "Reply with exactly the word PONG and nothing else.")

    assert turn["status"] == "completed", inspect(turn)
    assert List.last(agent_messages(items)) =~ "PONG"
  end

  test "qwen drives a tool call (exec_command) through codex", %{gateway_url: gateway_url} do
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
             &(&1["type"] == "commandExecution" and (&1["aggregatedOutput"] || "") =~ secret)
           )

    assert List.last(agent_messages(items)) =~ secret
  end

  test "the model's own web search: codex's hosted web_search tool goes to Bailian and the search shows as an item",
       %{gateway_url: gateway_url} do
    assert AI.web_search_mode() == :hosted

    home = prepare_home!(gateway_url)
    conn = start_connection!(home)
    thread_id = start_thread!(conn, home)

    {turn, items} =
      run_turn!(
        conn,
        thread_id,
        "上网搜一下：今天上海的天气怎么样？一句话回答，并说明你搜索了。",
        200_000
      )

    assert turn["status"] == "completed", inspect(turn)

    IO.inspect(Enum.map(items, &Map.take(&1, ["type", "query", "action", "status"])),
      label: "items"
    )

    assert Enum.any?(items, &(&1["type"] == "webSearch")), inspect(items)
    assert List.last(agent_messages(items)) =~ ~r/上海/
  end
end
