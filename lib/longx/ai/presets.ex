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

  A bump of these is a code change, reviewed like one.
  """

  alias Longx.AI
  alias Longx.AI.{Model, Provider}

  @type preset_model :: %{
          upstream_id: String.t(),
          slug: String.t(),
          name: String.t(),
          context_window: pos_integer,
          reasoning_levels: [String.t()],
          reasoning_effort: String.t() | nil,
          image: boolean,
          recommended: boolean
        }

  @type preset :: %{
          slug: String.t(),
          name: String.t(),
          kind: :openai | :openai_compatible,
          base_url: String.t(),
          supports_hosted_web_search: boolean,
          key_env: String.t(),
          key_url: String.t(),
          docs_url: String.t(),
          models: [preset_model]
        }

  @openai_levels ~w(low medium high xhigh max)
  @ds_levels ~w(low high max)

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
          reasoning_levels: @ds_levels,
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
            recommended: recommended
          }
        end
    }
  ]

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
         {:ok, provider} <- upsert_provider(preset, Keyword.get(opts, :api_key)),
         {:ok, models} <- upsert_models(provider, chosen),
         :ok <- maybe_make_default(models, Keyword.get(opts, :make_default, false)) do
      {:ok, %{provider: provider, models: models}}
    end
  end

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

  defp upsert_provider(preset, api_key) do
    facts = %{
      name: preset.name,
      kind: preset.kind,
      base_url: preset.base_url,
      supports_hosted_web_search: preset.supports_hosted_web_search
    }

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
                 provider_id: provider.id
               }) do
            {:ok, model} -> {:cont, {:ok, acc ++ [model]}}
            {:error, _} = error -> {:halt, error}
          end
      end
    end)
  end

  # a row from before levels existed (none declared) learns the preset's;
  # its default level stays when it is one of them, else the preset's applies
  defp backfill_levels(
         %Model{reasoning_levels: []} = model,
         %{reasoning_levels: [_ | _] = levels} = spec
       ) do
    effort =
      if model.reasoning_effort in levels, do: model.reasoning_effort, else: spec.reasoning_effort

    AI.update_model(model, %{reasoning_levels: levels, reasoning_effort: effort})
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
