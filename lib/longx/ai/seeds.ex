defmodule Longx.AI.Seeds do
  @moduledoc """
  What a fresh Longx starts with — run by `priv/repo/seeds.exs` (so by
  `mix ash.setup`, `mix setup` and `mix test`) and by a release at boot,
  right after the migrations (`Longx.Application`, when `RELEASE_NAME` is
  set).

  Idempotent, on `Longx.AI.Presets`: the DeepSeek preset (its recommended
  models) with the key from `DEEPSEEK_API_KEY`, made the default model when
  nothing is the default yet; the OpenAI preset's provider alone (its
  models are one click away in the settings page) with `OPENAI_API_KEY`;
  Tavily for web search with `TAVILY_API_KEY`; the agent tools mirrored
  into the DB. Never downgrades an existing key to nil, never touches a
  window or level someone chose (a row without levels learns the preset's).
  """

  require Logger

  alias Longx.AI
  alias Longx.AI.Presets

  @spec run() :: :ok
  def run do
    deepseek_key = System.get_env("DEEPSEEK_API_KEY")
    {:ok, %{models: [flash | _]}} = Presets.apply("deepseek", api_key: deepseek_key)

    case AI.default_model!() do
      nil -> AI.make_default_model!(flash)
      _ -> :ok
    end

    unless is_binary(deepseek_key) or key?(flash) do
      Logger.info(
        "seeds: DEEPSEEK_API_KEY is not set — the deepseek provider has no key; configure one in Settings (the AI gateway answers 503 until then)"
      )
    end

    {:ok, _} = Presets.apply("openai", api_key: System.get_env("OPENAI_API_KEY"), models: [])

    # Web search for codex's `web.run` tool: Tavily, key from TAVILY_API_KEY.
    tavily_key = System.get_env("TAVILY_API_KEY")

    search_provider =
      case AI.get_search_provider_by_slug("tavily") do
        {:ok, %AI.SearchProvider{} = sp} ->
          if tavily_key, do: AI.update_search_provider!(sp, %{api_key: tavily_key}), else: sp

        {:error, _} ->
          AI.create_search_provider!(%{
            name: "Tavily",
            slug: "tavily",
            kind: :tavily,
            api_key: tavily_key
          })
      end

    case AI.default_search_provider!() do
      nil -> AI.make_default_search_provider!(search_provider)
      _ -> :ok
    end

    unless tavily_key do
      Logger.info(
        "seeds: TAVILY_API_KEY is not set — web search stays disabled until a key is configured"
      )
    end

    # Mirror the registered agent tools into the DB (the memory tools on, the rest off).
    AI.list_tools!()
    :ok
  end

  # a provider that already has a key (from an earlier run or the settings page)
  defp key?(model) do
    case Ash.load(model, provider: [:has_api_key?]) do
      {:ok, %{provider: %{has_api_key?: true}}} -> true
      _ -> false
    end
  end
end
