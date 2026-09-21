defmodule Longx.AI.PresetsTest do
  use Longx.DataCase, async: false

  alias Longx.AI
  alias Longx.AI.Presets

  setup do
    Ash.bulk_destroy!(AI.Model, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(AI.Provider, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(Longx.Credentials.Credential, :destroy, %{}, authorize?: false)
    :ok
  end

  test "the catalogue: DeepSeek, GLM and OpenAI with the facts codex needs" do
    assert Enum.map(Presets.all(), & &1.slug) == [
             "deepseek",
             "glm",
             "bailian-token-plan-personal",
             "bailian-token-plan-team",
             "openai",
             "chatgpt"
           ]

    {:ok, deepseek} = Presets.fetch("deepseek")
    assert deepseek.base_url == "https://api.deepseek.com/v1"
    assert deepseek.kind == :openai_compatible
    assert deepseek.key_env == "DEEPSEEK_API_KEY"
    assert [flash, pro] = deepseek.models
    assert %{upstream_id: "deepseek-flash", context_window: 1_000_000, image: true} = flash
    assert flash.reasoning_levels == ["none", "low", "high", "max"]
    assert flash.reasoning_effort == "high"
    assert pro.upstream_id == "deepseek-v4-pro"

    {:ok, glm} = Presets.fetch("glm")
    # the Responses endpoint, not the chat-completions one
    assert glm.base_url == "https://open.bigmodel.cn/api/v1"

    assert [
             %{upstream_id: "glm-5.3", reasoning_effort: "max"},
             %{upstream_id: "glm-5-turbo", reasoning_levels: []}
           ] = glm.models

    # Bailian: one endpoint for both plans, the team plan's catalogue is a superset;
    # search is the model's own for Qwen / DeepSeek-v4 / glm-5.2, Longx's for the rest
    {:ok, personal} = Presets.fetch("bailian-token-plan-personal")
    {:ok, team} = Presets.fetch("bailian-token-plan-team")
    assert personal.base_url == team.base_url
    assert personal.base_url =~ "token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"
    assert personal.supports_hosted_web_search and team.supports_hosted_web_search
    assert length(personal.models) == 10 and length(team.models) == 19

    assert Enum.map(personal.models, & &1.upstream_id) ==
             Enum.map(Enum.take(team.models, 10), & &1.upstream_id)

    assert %{
             context_window: 983_616,
             reasoning_levels: ["low", "medium", "xhigh"],
             reasoning_effort: "xhigh",
             image: true,
             hosted_search: true
           } = hd(personal.models)

    assert Enum.all?(personal.models, & &1.hosted_search)

    assert Enum.map(Enum.filter(team.models, &(not &1.hosted_search)), & &1.upstream_id) ==
             [
               "deepseek-v3.2",
               "kimi-k2.7-code",
               "kimi-k2.6",
               "kimi-k2.5",
               "glm-5.1",
               "glm-5",
               "MiniMax-M2.5"
             ]

    {:ok, openai} = Presets.fetch("openai")
    assert openai.kind == :openai
    assert openai.supports_hosted_web_search
    assert Enum.count(openai.models, & &1.recommended) == 3
    # every model's default level is one it offers (the row's own rule)
    for preset <- Presets.all(), model <- preset.models, model.reasoning_levels != [] do
      assert model.reasoning_effort in model.reasoning_levels, model.upstream_id
    end

    assert Presets.fetch("nope") == :error
  end

  describe "apply/2" do
    test "chatgpt: a subscription — the Codex app's OAuth2 credential (fixed client, device-code login, the vendor's redirect), the provider on it, the models; idempotent" do
      assert {:ok, %{provider: provider, models: models, credential: cred}} =
               Presets.apply("chatgpt")

      assert provider.slug == "chatgpt"
      assert provider.base_url == "https://chatgpt.com/backend-api/codex"
      assert provider.kind == :openai
      assert provider.credential_id == cred.id
      assert Ash.load!(provider, :api_key).api_key == nil

      assert %Longx.Credentials.Credential{
               name: "chatgpt",
               kind: :oauth2,
               client_id: "app_EMoamEEZ73f0CkXaXp7hrann",
               authorize_url: "https://auth.openai.com/oauth/authorize",
               token_url: "https://auth.openai.com/oauth/token",
               scopes: "openid profile email offline_access",
               fixed_client: true,
               device_flow: :openai,
               redirect_uri: "http://localhost:1455/auth/callback",
               pkce: true
             } = cred

      assert "chatgpt.com" in cred.allowed_hosts and "auth.openai.com" in cred.allowed_hosts
      assert cred.authorize_params["codex_cli_simplified_flow"] == "true"
      assert cred.authorize_params["id_token_add_organizations"] == "true"
      assert cred.authorize_params["originator"] == "codex_cli_rs"
      assert "gpt-5.6-sol" in Enum.map(models, & &1.slug)
      # the subscription's models draw (OpenAI's hosted image_generation tool)
      assert Enum.all?(models, & &1.image_generation)
      # and answer short, as codex asks gpt-5.x to (text.verbosity low)
      assert Enum.all?(models, &(&1.verbosity == "low"))

      # the models' slugs are the plain ones when free, else prefixed (the openai preset took them?)
      assert Enum.all?(models, &(&1.provider_id == provider.id))

      # again: the same credential and provider, nothing doubled
      assert {:ok, %{provider: again, credential: cred_again}} = Presets.apply("chatgpt")
      assert again.id == provider.id and cred_again.id == cred.id
      assert length(Longx.Credentials.list()) == 1
    end

    test "creates the provider and the recommended models, the key on the provider" do
      assert {:ok, %{provider: provider, models: models}} =
               Presets.apply("deepseek", api_key: "sk-ds")

      assert provider.slug == "deepseek"
      assert provider.base_url == "https://api.deepseek.com/v1"
      assert Ash.load!(provider, :api_key).api_key == "sk-ds"
      assert Enum.map(models, & &1.upstream_id) == ["deepseek-flash", "deepseek-v4-pro"]
      # no drawing outside OpenAI's API, and no verbosity sent: DeepSeek ignores it
      refute Enum.any?(models, & &1.image_generation)
      assert Enum.all?(models, &is_nil(&1.verbosity))
      assert Enum.map(models, & &1.slug) == ["deepseek-flash", "deepseek-v4-pro"]
      [flash | _] = models
      assert flash.context_window == 1_000_000
      assert flash.reasoning_levels == ["none", "low", "high", "max"]
      assert flash.reasoning_effort == "high"
      assert flash.provider_id == provider.id
      # nothing was made the default unless asked
      assert AI.default_model!() == nil
    end

    test "is idempotent: an existing provider keeps its key and its models keep their edits" do
      {:ok, %{models: [flash, _]}} = Presets.apply("deepseek", api_key: "sk-first")
      AI.update_model!(flash, %{context_window: 200_000, reasoning_effort: "low"})

      # a second run without a key: facts refreshed, key kept, rows untouched
      {:ok, %{provider: provider, models: [flash2, _]}} = Presets.apply("deepseek")
      assert Ash.load!(provider, :api_key).api_key == "sk-first"
      assert flash2.id == flash.id
      assert flash2.context_window == 200_000
      assert flash2.reasoning_effort == "low"
      assert length(AI.list_models!()) == 2

      # a new key replaces the old one
      {:ok, %{provider: provider}} = Presets.apply("deepseek", api_key: "sk-second")
      assert Ash.load!(provider, :api_key).api_key == "sk-second"
    end

    test "a row from before levels existed learns the preset's; its default level stays when it is one of them" do
      provider =
        AI.create_provider!(%{
          name: "DeepSeek",
          slug: "deepseek",
          base_url: "https://api.deepseek.com/v1"
        })

      old =
        AI.create_model!(%{
          name: "Flash",
          upstream_id: "deepseek-flash",
          provider_id: provider.id,
          reasoning_effort: "low"
        })

      free =
        AI.create_model!(%{
          name: "Pro",
          upstream_id: "deepseek-v4-pro",
          provider_id: provider.id,
          reasoning_effort: "xhigh"
        })

      {:ok, %{models: [flash, pro]}} = Presets.apply("deepseek")
      assert flash.id == old.id
      assert flash.reasoning_levels == ["none", "low", "high", "max"]
      assert flash.reasoning_effort == "low"
      # "xhigh" is not a DeepSeek level: the preset's default replaces it
      assert pro.id == free.id
      assert pro.reasoning_effort == "high"

      # a row on an older, smaller set of the preset's levels gains the new ones
      # (DeepSeek added `none`); a set with a level of its own is left alone
      AI.update_model!(flash, %{reasoning_levels: ["low", "high", "max"], reasoning_effort: "max"})

      {:ok, %{models: [flash, _]}} = Presets.apply("deepseek")
      assert flash.reasoning_levels == ["none", "low", "high", "max"]
      assert flash.reasoning_effort == "max"
      AI.update_model!(flash, %{reasoning_levels: ["low", "deep"], reasoning_effort: "low"})
      {:ok, %{models: [flash, _]}} = Presets.apply("deepseek")
      assert flash.reasoning_levels == ["low", "deep"]
    end

    test "Bailian: the model rows carry the per-model search flag, so kimi searches through Longx and qwen through Bailian" do
      assert {:ok, %{provider: provider, models: [qwen, kimi]}} =
               Presets.apply("bailian-token-plan-team",
                 api_key: "sk-sp-x",
                 models: ["qwen3.8-max", "kimi-k2.7-code"]
               )

      assert provider.supports_hosted_web_search
      assert qwen.hosted_web_search == true and kimi.hosted_web_search == false
      assert AI.web_search_mode(qwen) == :hosted
      assert AI.web_search_mode(kimi) == :standalone
      # the slugs are the upstream ids (deepseek-v4-pro would collide with DeepSeek's: prefixed)
      {:ok, %{models: [pro]}} = Presets.apply("deepseek", models: ["deepseek-v4-pro"])

      {:ok, %{models: [bailian_pro]}} =
        Presets.apply("bailian-token-plan-personal", api_key: "k", models: ["deepseek-v4-pro"])

      assert pro.slug == "deepseek-v4-pro" and
               bailian_pro.slug == "bailian-token-plan-personal-deepseek-v4-pro"
    end

    test "models: picks by upstream id, :all takes everything; make_default: names the default" do
      assert {:ok, %{models: [pro]}} =
               Presets.apply("openai", models: ["gpt-5.5"], make_default: "gpt-5.5")

      assert pro.upstream_id == "gpt-5.5"
      assert AI.default_model!().id == pro.id

      assert {:ok, %{models: models}} = Presets.apply("openai", models: :all)
      assert length(models) == 6
      # the row created before is the same row
      assert Enum.find(models, &(&1.upstream_id == "gpt-5.5")).id == pro.id

      assert {:error, {:unknown_model, "gpt-9"}} = Presets.apply("openai", models: ["gpt-9"])
      assert {:error, :unknown_preset} = Presets.apply("nope")

      # make_default: true is the first chosen model
      assert {:ok, %{models: [turbo]}} =
               Presets.apply("glm", models: ["glm-5-turbo"], make_default: true)

      assert AI.default_model!().id == turbo.id
    end

    test "a slug another provider's model took is prefixed with the provider's" do
      other =
        AI.create_provider!(%{name: "Other", slug: "other", base_url: "https://x.example/v1"})

      AI.create_model!(%{name: "Mine", upstream_id: "deepseek-flash", provider_id: other.id})

      {:ok, %{models: [flash, _]}} = Presets.apply("deepseek")
      assert flash.slug == "deepseek-deepseek-flash"
    end
  end
end
