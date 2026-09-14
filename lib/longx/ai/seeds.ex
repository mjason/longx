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
    search_provider =
      case AI.get_search_provider_by_slug("tavily") do
        {:ok, %AI.SearchProvider{} = sp} ->
          sp

        {:error, _} ->
          AI.create_search_provider!(%{name: "Tavily", slug: "tavily", kind: :tavily})
      end

    case AI.default_search_provider!() do
      nil -> AI.make_default_search_provider!(search_provider)
      _ -> :ok
    end

    # Mirror the registered agent tools into the DB (the memory tools on, the rest off).
    AI.list_tools!()
    :ok
  end
end
