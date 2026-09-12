# Seeds — run by `mix ash.setup` (and therefore by `mix setup` and `mix test`).
#
# Idempotent: creates the DeepSeek provider and `deepseek-flash` model if they
# are missing, refreshes the provider's key from DEEPSEEK_API_KEY when that is
# set, and makes deepseek-flash the default model when nothing is the default
# yet. Safe to re-run; never downgrades an existing key to nil.

alias Longx.AI

deepseek_key = System.get_env("DEEPSEEK_API_KEY")

provider =
  case AI.get_provider_by_slug("deepseek") do
    {:ok, %AI.Provider{} = provider} ->
      if deepseek_key, do: AI.update_provider!(provider, %{api_key: deepseek_key}), else: provider

    {:error, _} ->
      AI.create_provider!(%{
        name: "DeepSeek",
        slug: "deepseek",
        base_url: "https://api.deepseek.com/v1",
        api_key: deepseek_key
      })
  end

model =
  case Enum.find(
         AI.list_models!(),
         &(&1.upstream_id == "deepseek-flash" and &1.provider_id == provider.id)
       ) do
    nil ->
      AI.create_model!(%{
        name: "DeepSeek Flash",
        upstream_id: "deepseek-flash",
        context_window: 128_000,
        provider_id: provider.id
      })

    model ->
      model
  end

case AI.default_model!() do
  nil -> AI.make_default_model!(model)
  _ -> :ok
end

unless deepseek_key do
  IO.puts(
    "seeds: DEEPSEEK_API_KEY is not set — the deepseek provider has no key; the AI gateway will answer 503 until one is configured"
  )
end

# OpenAI: not the default, but present so its hosted web_search is one click
# away; key from OPENAI_API_KEY when set.
openai_key = System.get_env("OPENAI_API_KEY")

case AI.get_provider_by_slug("openai") do
  {:ok, %AI.Provider{} = openai} ->
    if openai_key, do: AI.update_provider!(openai, %{api_key: openai_key})

  {:error, _} ->
    AI.create_provider!(%{
      name: "OpenAI",
      slug: "openai",
      base_url: "https://api.openai.com/v1",
      api_key: openai_key,
      supports_hosted_web_search: true
    })
end

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
