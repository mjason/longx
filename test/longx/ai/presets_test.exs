defmodule Longx.AI.PresetsTest do
  use Longx.DataCase, async: false

  alias Longx.AI
  alias Longx.AI.Presets

  setup do
    Ash.bulk_destroy!(AI.Model, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(AI.Provider, :destroy, %{}, authorize?: false)
    :ok
  end

  test "the catalogue: DeepSeek, GLM and OpenAI with the facts codex needs" do
    assert Enum.map(Presets.all(), & &1.slug) == ["deepseek", "glm", "openai"]

    {:ok, deepseek} = Presets.fetch("deepseek")
    assert deepseek.base_url == "https://api.deepseek.com/v1"
    assert deepseek.kind == :openai_compatible
    assert deepseek.key_env == "DEEPSEEK_API_KEY"
    assert [flash, pro] = deepseek.models
    assert %{upstream_id: "deepseek-flash", context_window: 1_000_000, image: true} = flash
    assert flash.reasoning_levels == ["low", "high", "max"]
    assert flash.reasoning_effort == "high"
    assert pro.upstream_id == "deepseek-v4-pro"

    {:ok, glm} = Presets.fetch("glm")
    # the Responses endpoint, not the chat-completions one
    assert glm.base_url == "https://open.bigmodel.cn/api/v1"

    assert [
             %{upstream_id: "glm-5.3", reasoning_effort: "max"},
             %{upstream_id: "glm-5-turbo", reasoning_levels: []}
           ] = glm.models

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
    test "creates the provider and the recommended models, the key on the provider" do
      assert {:ok, %{provider: provider, models: models}} =
               Presets.apply("deepseek", api_key: "sk-ds")

      assert provider.slug == "deepseek"
      assert provider.base_url == "https://api.deepseek.com/v1"
      assert Ash.load!(provider, :api_key).api_key == "sk-ds"
      assert Enum.map(models, & &1.upstream_id) == ["deepseek-flash", "deepseek-v4-pro"]
      assert Enum.map(models, & &1.slug) == ["deepseek-flash", "deepseek-v4-pro"]
      [flash | _] = models
      assert flash.context_window == 1_000_000
      assert flash.reasoning_levels == ["low", "high", "max"]
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
      assert flash.reasoning_levels == ["low", "high", "max"]
      assert flash.reasoning_effort == "low"
      # "xhigh" is not a DeepSeek level: the preset's default replaces it
      assert pro.id == free.id
      assert pro.reasoning_effort == "high"
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
