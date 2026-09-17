defmodule Longx.AI.Seeds do
  @moduledoc """
  What a development / test database starts with — run by
  `priv/repo/seeds.exs` (so by `mix ash.setup`, `mix setup` and `mix test`).
  A release seeds nothing: providers and keys are created in Settings.

  Idempotent, on `Longx.AI.Presets`: the DeepSeek preset (its recommended
  models, no key) as the default model when nothing is the default yet, the
  OpenAI preset's provider alone, a Tavily row for web search, the agent
  tools mirrored into the DB. Never touches a key, a window or a level
  someone chose.
  """

  alias Longx.AI
  alias Longx.AI.Presets

  @spec run() :: :ok
  def run do
    {:ok, %{models: [flash | _]}} = Presets.apply("deepseek")

    case AI.default_model!() do
      nil -> AI.make_default_model!(flash)
      _ -> :ok
    end

    {:ok, _} = Presets.apply("openai", models: [])

    # Web search for codex's `web.run` tool: Tavily; the key is set in Settings.
    {:ok, _} = AI.ensure_search_provider()

    # Mirror the registered agent tools into the DB (new tools off).
    AI.list_tools!()
    :ok
  end
end
