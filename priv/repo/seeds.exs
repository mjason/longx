# Seeds — run by `mix ash.setup` (and therefore by `mix setup` and `mix test`).
#
# Idempotent, on `Longx.AI.Presets`: the DeepSeek preset (its recommended
# models) with the key from DEEPSEEK_API_KEY, made the default model when
# nothing is the default yet; the OpenAI preset's provider alone (its models
# are one click away in the settings page) with OPENAI_API_KEY. Safe to
# re-run; never downgrades an existing key to nil, never touches a window
# or level someone chose (a row without levels learns the preset's).

alias Longx.AI
alias Longx.AI.Presets

deepseek_key = System.get_env("DEEPSEEK_API_KEY")

{:ok, %{models: [flash | _]}} = Presets.apply("deepseek", api_key: deepseek_key)

case AI.default_model!() do
  nil -> AI.make_default_model!(flash)
  _ -> :ok
end

unless deepseek_key do
  IO.puts(
    "seeds: DEEPSEEK_API_KEY is not set — the deepseek provider has no key; the AI gateway will answer 503 until one is configured"
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
  IO.puts(
    "seeds: TAVILY_API_KEY is not set — web search stays disabled until a key is configured"
  )
end

# Mirror the registered agent tools into the DB (all disabled until someone turns them on).
AI.list_tools!()
