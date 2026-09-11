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

  test "a real DeepSeek turn completes end to end" do
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

    {:ok, bandit} =
      start_supervised(
        {Bandit, plug: LongxWeb.Endpoint, scheme: :http, ip: {127, 0, 0, 1}, port: 0}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)

    home_dir =
      Path.join(Path.expand("data"), "codex_home_live_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(home_dir) end)
    {:ok, home} = Home.prepare(dir: home_dir, gateway_url: "http://127.0.0.1:#{port}/ai/v1")

    {shim, thread_id} = CodexClient.start_thread(home)

    turn =
      CodexClient.run_turn(shim, thread_id, "Reply with exactly the word PONG and nothing else.")

    assert turn["status"] == "completed", "turn did not complete: #{inspect(turn)}"
    assert_received {:agent_message, text}
    assert text =~ "PONG"

    CodexClient.stop(shim)
  end
end
