defmodule Longx.AI.Presets do
  @moduledoc """
  Ready-made provider configurations: the facts about a vendor a person
  should not have to look up (endpoint, kind, hosted search) and its models
  as codex should know them (window, reasoning levels, default level).

  Pure data plus `apply/2`, which turns a preset into `Longx.AI.Provider` /
  `Longx.AI.Model` rows without duplicating what exists. Sources:

    * **OpenAI** — the model catalog embedded in the pinned codex binary
      (`strings` the binary for `"supported_reasoning_levels"`): the models
      it lists as visible and API-capable, with codex's own default window.
    * **DeepSeek** — the `models.json` DeepSeek publishes for codex
      (api-docs.deepseek.com, "接入 Codex"): `deepseek-flash` (image input)
      and `deepseek-v4-pro`, 1M, `low / high / max` defaulting to `high`.
      Their Responses API accepts `reasoning.effort` and ignores summaries.
    * **GLM** — the `models.json` on docs.bigmodel.cn ("Codex"): the
      Responses endpoint is `/api/v1` (not the chat-completions `/api/paas/v4`),
      `glm-5.3` (1M, `low / high / max`, default `max`) and `glm-5-turbo`
      (200k, no levels).
    * **阿里云百炼 Token Plan** (个人版 / 团队版) — the `model-catalog.local.json`
      on docs.bailian.console.aliyun.com ("Codex"): one endpoint for both
      plans (`token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1`,
      Responses API; the keys differ per plan and are not interchangeable),
      windows / levels / default levels / image input as published; the
      team plan lists nine models more. **Search is per model**: Bailian
      runs codex's standard `web_search` tool for Qwen 3.5+, DeepSeek-v4 and
      glm-5.2 (`web_search_call` items with the query and sources come back
      in the stream — verified live through codex) and refuses it for
      kimi-k2.x, MiniMax and glm-5 / 5.1 ("Agent capabilities are not
      enabled"), so those get `hosted_search: false` → Longx's own search.
      Coding Plan is chat-completions only (codex 0.154 dropped that);
      pay-as-you-go needs a WorkspaceId in the URL — a custom provider.

  A bump of these is a code change, reviewed like one.
  """

  alias Longx.AI
  alias Longx.AI.{Model, Provider}

  @type preset_model :: %{
          required(:upstream_id) => String.t(),
          required(:slug) => String.t(),
          required(:name) => String.t(),
          required(:context_window) => pos_integer,
          required(:reasoning_levels) => [String.t()],
          required(:reasoning_effort) => String.t() | nil,
          required(:image) => boolean,
          required(:recommended) => boolean,
          # the model runs codex's web_search tool itself (absent: the provider's say)
          optional(:hosted_search) => boolean
        }

  @type preset :: %{
          required(:slug) => String.t(),
          required(:name) => String.t(),
          required(:kind) => :openai | :openai_compatible,
          required(:base_url) => String.t(),
          required(:supports_hosted_web_search) => boolean,
          required(:key_env) => String.t(),
          required(:key_url) => String.t(),
          required(:docs_url) => String.t(),
          optional(:credential) => boolean,
          required(:models) => [preset_model]
        }

  @openai_levels ~w(low medium high xhigh max)
  # Bailian's catalog: qwen3.8 declares low / medium / xhigh (default xhigh),
  # everything else low / medium / high / xhigh (default medium)
  @bailian_short ~w(low medium xhigh)
  @bailian_full ~w(low medium high xhigh)
  @bailian_url "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"

  # {upstream id, window, levels, default, image, hosted search, recommended}
  @bailian_personal [
    {"qwen3.8-max", 983_616, @bailian_short, "xhigh", true, true, true},
    {"qwen3.8-flash", 983_616, @bailian_short, "xhigh", true, true, true},
    {"qwen3.7-max", 1_000_000, @bailian_full, "medium", false, true, false},
    {"qwen3.7-plus", 1_000_000, @bailian_full, "medium", true, true, false},
    {"qwen3.6-flash", 1_000_000, @bailian_full, "medium", true, true, false},
    {"glm-5.2", 1_000_000, @bailian_full, "medium", false, true, true},
    {"deepseek-v4.1-flash", 1_000_000, @bailian_full, "medium", true, true, false},
    {"deepseek-v4-pro", 163_840, @bailian_full, "medium", false, true, true},
    {"deepseek-v4-pro-0813", 163_840, @bailian_full, "medium", false, true, false},
    {"deepseek-v4-flash-0731", 1_000_000, @bailian_full, "medium", false, true, false}
  ]
  @bailian_team_extra [
    {"qwen3.6-plus", 1_000_000, @bailian_full, "medium", true, true, false},
    {"deepseek-v4-flash", 163_840, @bailian_full, "medium", false, true, false},
    {"deepseek-v3.2", 163_840, @bailian_full, "medium", false, false, false},
    {"kimi-k2.7-code", 262_144, @bailian_full, "medium", true, false, true},
    {"kimi-k2.6", 262_144, @bailian_full, "medium", true, false, false},
    {"kimi-k2.5", 262_144, @bailian_full, "medium", true, false, false},
    {"glm-5.1", 202_752, @bailian_full, "medium", false, false, false},
    {"glm-5", 202_752, @bailian_full, "medium", false, false, false},
    {"MiniMax-M2.5", 204_800, @bailian_full, "medium", false, false, false}
  ]
  # DeepSeek's Responses API takes `reasoning.effort` none / low / high / max
  # (none = thinking off; minimal → low, medium / xhigh → high, ultra → max
  # are only aliases) — docs: 思考模式 → 控制参数（Responses API 格式）
  @ds_levels ~w(none low high max)
  # GLM's own models.json for codex declares low / high / max
  @glm_levels ~w(low high max)

  @presets [
    %{
      slug: "deepseek",
      name: "DeepSeek",
      kind: :openai_compatible,
      base_url: "https://api.deepseek.com/v1",
      supports_hosted_web_search: false,
      key_env: "DEEPSEEK_API_KEY",
      key_url: "https://platform.deepseek.com/api_keys",
      docs_url: "https://api-docs.deepseek.com/zh-cn/quick_start/agent_integrations/codex",
      models: [
        %{
          upstream_id: "deepseek-flash",
          slug: "deepseek-flash",
          name: "DeepSeek Flash",
          context_window: 1_000_000,
          reasoning_levels: @ds_levels,
          reasoning_effort: "high",
          image: true,
          recommended: true
        },
        %{
          upstream_id: "deepseek-v4-pro",
          slug: "deepseek-v4-pro",
          name: "DeepSeek V4 Pro",
          context_window: 1_000_000,
          reasoning_levels: @ds_levels,
          reasoning_effort: "high",
          image: false,
          recommended: true
        }
      ]
    },
    %{
      slug: "glm",
      name: "GLM",
      kind: :openai_compatible,
      base_url: "https://open.bigmodel.cn/api/v1",
      supports_hosted_web_search: false,
      key_env: "GLM_API_KEY",
      key_url: "https://bigmodel.cn/usercenter/proj-mgmt/apikeys",
      docs_url: "https://docs.bigmodel.cn/cn/coding-plan/tool/codex",
      models: [
        %{
          upstream_id: "glm-5.3",
          slug: "glm-5.3",
          name: "GLM 5.3",
          context_window: 1_000_000,
          reasoning_levels: @glm_levels,
          reasoning_effort: "max",
          image: false,
          recommended: true
        },
        %{
          upstream_id: "glm-5-turbo",
          slug: "glm-5-turbo",
          name: "GLM 5 Turbo",
          context_window: 200_000,
          reasoning_levels: [],
          reasoning_effort: nil,
          image: false,
          recommended: true
        }
      ]
    },
    %{
      slug: "bailian-token-plan-personal",
      name: "阿里云百炼 Token Plan 个人版",
      kind: :openai_compatible,
      base_url: @bailian_url,
      supports_hosted_web_search: true,
      key_env: "BAILIAN_TOKEN_PLAN_API_KEY",
      key_url: "https://bailian.console.aliyun.com/?tab=tokenplan#/token-plan",
      docs_url: "https://docs.bailian.console.aliyun.com/zh/model-studio/codex",
      models:
        for {id, window, levels, effort, image, search, recommended} <- @bailian_personal do
          %{
            upstream_id: id,
            slug: id,
            name: id,
            context_window: window,
            reasoning_levels: levels,
            reasoning_effort: effort,
            image: image,
            hosted_search: search,
            recommended: recommended
          }
        end
    },
    %{
      slug: "bailian-token-plan-team",
      name: "阿里云百炼 Token Plan 团队版",
      kind: :openai_compatible,
      base_url: @bailian_url,
      supports_hosted_web_search: true,
      key_env: "BAILIAN_TOKEN_PLAN_TEAM_API_KEY",
      key_url: "https://bailian.console.aliyun.com/?tab=tokenplan#/token-plan",
      docs_url: "https://docs.bailian.console.aliyun.com/zh/model-studio/codex",
      models:
        for {id, window, levels, effort, image, search, recommended} <-
              @bailian_personal ++ @bailian_team_extra do
          %{
            upstream_id: id,
            slug: id,
            name: id,
            context_window: window,
            reasoning_levels: levels,
            reasoning_effort: effort,
            image: image,
            hosted_search: search,
            recommended: recommended
          }
        end
    },
    %{
      slug: "openai",
      name: "OpenAI",
      kind: :openai,
      base_url: "https://api.openai.com/v1",
      supports_hosted_web_search: true,
      key_env: "OPENAI_API_KEY",
      key_url: "https://platform.openai.com/api-keys",
      docs_url: "https://developers.openai.com/codex",
      models:
        for {upstream_id, name, effort, levels, recommended} <- [
              {"gpt-5.6-sol", "GPT-5.6 Sol", "low", @openai_levels ++ ["ultra"], true},
              {"gpt-5.6-terra", "GPT-5.6 Terra", "medium", @openai_levels ++ ["ultra"], true},
              {"gpt-5.6-luna", "GPT-5.6 Luna", "medium", @openai_levels, true},
              {"gpt-6-astra", "GPT-6 Astra", "low", @openai_levels ++ ["ultra"], false},
              {"gpt-5.5", "GPT-5.5", "medium", ~w(low medium high xhigh), false},
              {"gpt-5.2", "GPT-5.2", "medium", ~w(low medium high xhigh), false}
            ] do
          %{
            upstream_id: upstream_id,
            slug: upstream_id,
            name: name,
            context_window: 272_000,
            reasoning_levels: levels,
            reasoning_effort: effort,
            image: true,
            # OpenAI's Responses API draws on its side (the image_generation tool)
            image_generation: true,
            recommended: recommended
          }
        end
    },
    %{
      slug: "chatgpt",
      name: "OpenAI（ChatGPT 订阅）",
      kind: :openai,
      base_url: "https://chatgpt.com/backend-api/codex",
      supports_hosted_web_search: false,
      key_env: "",
      key_url: "https://chatgpt.com/",
      docs_url: "https://developers.openai.com/codex",
      # the key is a login, not a string: `credential: true` tells the page and `apply/2`
      credential: true,
      models:
        for {upstream_id, name, effort, levels, recommended} <- [
              {"gpt-5.6-sol", "GPT-5.6 Sol", "low", @openai_levels ++ ["ultra"], true},
              {"gpt-5.6-terra", "GPT-5.6 Terra", "medium", @openai_levels ++ ["ultra"], true},
              {"gpt-5.6-luna", "GPT-5.6 Luna", "medium", @openai_levels, false},
              {"gpt-6-astra", "GPT-6 Astra", "low", @openai_levels ++ ["ultra"], false},
              {"gpt-5.5", "GPT-5.5", "medium", ~w(low medium high xhigh), false}
            ] do
          %{
            upstream_id: upstream_id,
            slug: upstream_id,
            name: name,
            context_window: 272_000,
            reasoning_levels: levels,
            reasoning_effort: effort,
            image: true,
            image_generation: true,
            recommended: recommended
          }
        end
    }
  ]

  # A ChatGPT subscription through the Codex backend: no API key — the Codex
  # CLI's own OAuth2 client (public, PKCE, fixed by OpenAI), logged in with
  # the device code (no port, no redirect to catch) or the browser (the
  # person pastes the localhost:1455 address back). The credential is the
  # provider's key (`credential_id`); it refreshes itself. The originator
  # is the Codex CLI's: the backend serves only clients it knows.
  @chatgpt_credential %{
    name: "chatgpt",
    label: "ChatGPT（Codex）",
    allowed_hosts: ["chatgpt.com", "auth.openai.com"],
    client_id: "app_EMoamEEZ73f0CkXaXp7hrann",
    authorize_url: "https://auth.openai.com/oauth/authorize",
    token_url: "https://auth.openai.com/oauth/token",
    scopes: "openid profile email offline_access",
    pkce: true,
    fixed_client: true,
    device_flow: :openai,
    redirect_uri: "http://localhost:1455/auth/callback",
    authorize_params: %{
      "id_token_add_organizations" => "true",
      "codex_cli_simplified_flow" => "true",
      "originator" => "codex_cli_rs"
    }
  }

  @doc "The OAuth2 credential the `chatgpt` preset makes (tests, the settings page's words)."
  @spec chatgpt_credential() :: map
  def chatgpt_credential, do: @chatgpt_credential

  @doc "Every preset, in the order the settings page shows them."
  @spec all() :: [preset]
  def all, do: @presets

  @doc """
  The presets as the settings page shows them: each with `installed` (a
  provider with the preset's slug exists), its `provider_id`, and every
  model flagged `installed` (a row with that upstream id under it).
  """
  @spec describe() :: [map]
  def describe do
    providers = Map.new(AI.list_providers!(), &{&1.slug, &1})
    models = AI.list_models!()

    for preset <- @presets do
      provider = Map.get(providers, preset.slug)

      have =
        if provider,
          do: for(m <- models, m.provider_id == provider.id, do: m.upstream_id),
          else: []

      preset
      |> Map.put(:installed, provider != nil)
      |> Map.put(:credential, Map.get(preset, :credential, false))
      |> Map.put(:provider_id, provider && provider.id)
      |> Map.put(
        :models,
        Enum.map(preset.models, &Map.put(&1, :installed, &1.upstream_id in have))
      )
    end
  end

  @spec fetch(String.t()) :: {:ok, preset} | :error
  def fetch(slug) do
    case Enum.find(@presets, &(&1.slug == slug)) do
      nil -> :error
      preset -> {:ok, preset}
    end
  end

  @type apply_option ::
          {:api_key, String.t() | nil}
          | {:models, [String.t()] | :all | :recommended}
          | {:make_default, String.t() | boolean}

  @doc """
  Creates (or refreshes) the preset's provider and the chosen models.

  The provider is matched by slug: an existing one gets the preset's
  endpoint / kind / search capability and, when `api_key:` is given, the
  key — a key it already has is never dropped. Models are matched by
  `upstream_id` under that provider: existing rows keep the person's edits
  (window, levels, default level — a row that declares no levels learns the
  preset's), new ones are created from the preset.
  `models:` is a list of upstream ids, `:recommended` (default) or `:all`.
  `make_default:` names the upstream id to make the global default, or
  `true` for the first chosen model; it is only applied when the catalogue
  has no default yet unless given explicitly.

  Returns the provider and the models it now has for the chosen ids.
  """
  @spec apply(String.t(), [apply_option]) ::
          {:ok, %{provider: Provider.t(), models: [Model.t()]}}
          | {:error, :unknown_preset | {:unknown_model, String.t()} | term}
  def apply(slug, opts \\ []) do
    with {:ok, preset} <- fetch_preset(slug),
         {:ok, chosen} <- chosen_models(preset, Keyword.get(opts, :models, :recommended)),
         {:ok, credential} <- upsert_credential(preset),
         {:ok, provider} <- upsert_provider(preset, Keyword.get(opts, :api_key), credential),
         {:ok, models} <- upsert_models(provider, chosen),
         :ok <- maybe_make_default(models, Keyword.get(opts, :make_default, false)) do
      {:ok, %{provider: provider, models: models, credential: credential}}
    end
  end

  # a preset whose key is a login makes (or keeps) its OAuth2 credential
  defp upsert_credential(%{credential: true}) do
    case Longx.Credentials.fetch(@chatgpt_credential.name) do
      {:ok, cred} -> {:ok, cred}
      {:error, _} -> Longx.Credentials.create_oauth2(@chatgpt_credential)
    end
  end

  defp upsert_credential(_preset), do: {:ok, nil}

  defp fetch_preset(slug) do
    case fetch(slug) do
      {:ok, preset} -> {:ok, preset}
      :error -> {:error, :unknown_preset}
    end
  end

  defp chosen_models(preset, :all), do: {:ok, preset.models}

  defp chosen_models(preset, :recommended),
    do: {:ok, Enum.filter(preset.models, & &1.recommended)}

  defp chosen_models(preset, ids) when is_list(ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case Enum.find(preset.models, &(&1.upstream_id == id)) do
        nil -> {:halt, {:error, {:unknown_model, id}}}
        model -> {:cont, {:ok, acc ++ [model]}}
      end
    end)
  end

  defp upsert_provider(preset, api_key, credential) do
    facts =
      %{
        name: preset.name,
        kind: preset.kind,
        base_url: preset.base_url,
        supports_hosted_web_search: preset.supports_hosted_web_search
      }
      |> then(&if(credential, do: Map.put(&1, :credential_id, credential.id), else: &1))

    case AI.get_provider_by_slug(preset.slug) do
      {:ok, %Provider{} = provider} ->
        AI.update_provider(
          provider,
          if(api_key, do: Map.put(facts, :api_key, api_key), else: facts)
        )

      {:error, _} ->
        AI.create_provider(Map.merge(facts, %{slug: preset.slug, api_key: api_key}))
    end
  end

  defp upsert_models(provider, chosen) do
    existing = AI.list_models!() |> Enum.filter(&(&1.provider_id == provider.id))

    Enum.reduce_while(chosen, {:ok, []}, fn spec, {:ok, acc} ->
      case Enum.find(existing, &(&1.upstream_id == spec.upstream_id)) do
        %Model{} = model ->
          case backfill_levels(model, spec) do
            {:ok, model} -> {:cont, {:ok, acc ++ [model]}}
            {:error, _} = error -> {:halt, error}
          end

        nil ->
          case AI.create_model(%{
                 name: spec.name,
                 slug: free_slug(provider, spec.slug),
                 upstream_id: spec.upstream_id,
                 context_window: spec.context_window,
                 reasoning_levels: spec.reasoning_levels,
                 reasoning_effort: spec.reasoning_effort,
                 hosted_web_search: Map.get(spec, :hosted_search),
                 image_generation: Map.get(spec, :image_generation, false),
                 verbosity: Map.get(spec, :verbosity),
                 provider_id: provider.id
               }) do
            {:ok, model} -> {:cont, {:ok, acc ++ [model]}}
            {:error, _} = error -> {:halt, error}
          end
      end
    end)
  end

  # a row from before levels existed (none declared) learns the preset's, and
  # a row on a smaller set of the preset's levels gains the ones added since
  # (a level more never breaks a thing); a set with a level of its own is the
  # person's and stays. The default level stays when it is one of them.
  defp backfill_levels(
         %Model{reasoning_levels: current} = model,
         %{reasoning_levels: [_ | _] = levels} = spec
       ) do
    subset? = current != levels and Enum.all?(current, &(&1 in levels))

    if subset? do
      effort =
        if model.reasoning_effort in levels,
          do: model.reasoning_effort,
          else: spec.reasoning_effort

      AI.update_model(model, %{reasoning_levels: levels, reasoning_effort: effort})
    else
      {:ok, model}
    end
  end

  defp backfill_levels(model, _spec), do: {:ok, model}

  # the preset's slug, or `<provider>-<slug>` when another provider's model
  # already took it (the slug is what codex and the person see)
  defp free_slug(provider, slug) do
    case AI.get_model_by_slug(slug) do
      {:ok, %Model{}} -> "#{provider.slug}-#{slug}"
      {:error, _} -> slug
    end
  end

  defp maybe_make_default(_models, false), do: :ok

  defp maybe_make_default(models, true) do
    case models do
      [first | _] -> make_default(first)
      [] -> :ok
    end
  end

  defp maybe_make_default(models, upstream_id) when is_binary(upstream_id) do
    case Enum.find(models, &(&1.upstream_id == upstream_id)) do
      nil -> {:error, {:unknown_model, upstream_id}}
      model -> make_default(model)
    end
  end

  defp make_default(model) do
    with {:ok, _} <- AI.make_default_model(model), do: :ok
  end
end
