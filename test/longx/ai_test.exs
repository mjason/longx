defmodule Longx.AITest do
  use Longx.DataCase, async: false

  alias Longx.AI

  # `mix test` runs the seeds, so the sandbox starts with the DeepSeek rows;
  # these tests reason about an empty catalogue.
  setup do
    Ash.bulk_destroy!(AI.Model, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(AI.Provider, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(AI.SearchProvider, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(AI.Tool, :destroy, %{}, authorize?: false)
    :ok
  end

  defp uniq, do: System.unique_integer([:positive])

  defp create_provider!(attrs \\ %{}) do
    n = uniq()

    AI.create_provider!(
      Map.merge(
        %{
          name: "Provider #{n}",
          slug: "provider-#{n}",
          base_url: "https://api.example.com/v1",
          api_key: "sk-secret-#{n}"
        },
        attrs
      )
    )
  end

  defp create_model!(provider, attrs \\ %{}) do
    n = uniq()

    AI.create_model!(
      Map.merge(%{name: "Model #{n}", upstream_id: "model-#{n}", provider_id: provider.id}, attrs)
    )
  end

  describe "providers" do
    test "api_key is stored encrypted and only decrypted when loaded" do
      provider = create_provider!(%{api_key: "sk-plain"})

      assert %Ash.NotLoaded{} = provider.api_key
      assert is_binary(provider.encrypted_api_key)
      refute provider.encrypted_api_key =~ "sk-plain"

      loaded = Ash.load!(provider, :api_key)
      assert loaded.api_key == "sk-plain"
    end

    test "has_api_key? reflects whether a key is set" do
      with_key = create_provider!() |> Ash.load!(:has_api_key?)
      without = create_provider!(%{api_key: nil}) |> Ash.load!(:has_api_key?)

      assert with_key.has_api_key?
      refute without.has_api_key?
    end

    test "slug is unique" do
      provider = create_provider!()

      assert {:error, %Ash.Error.Invalid{}} =
               AI.create_provider(%{name: "dup", slug: provider.slug, base_url: "https://x/v1"})
    end

    test "get_provider_by_slug/1 and update_provider/2 (rotating the key)" do
      provider = create_provider!(%{slug: "deepseek-#{uniq()}"})
      assert {:ok, found} = AI.get_provider_by_slug(provider.slug)
      assert found.id == provider.id

      updated = AI.update_provider!(provider, %{api_key: "sk-rotated"}) |> Ash.load!(:api_key)
      assert updated.api_key == "sk-rotated"
    end

    test "supports_hosted_web_search defaults to false (only OpenAI runs web_search server-side)" do
      refute create_provider!().supports_hosted_web_search
      assert create_provider!(%{supports_hosted_web_search: true}).supports_hosted_web_search
    end

    test "base_url must be http(s)" do
      assert {:error, %Ash.Error.Invalid{}} =
               AI.create_provider(%{name: "bad", slug: "bad-#{uniq()}", base_url: "ftp://nope"})
    end
  end

  describe "models" do
    test "belong to a provider and default to a 128k context window" do
      provider = create_provider!()
      model = create_model!(provider)

      assert model.provider_id == provider.id
      assert model.context_window == 128_000
      refute model.default
    end

    test "default_model/0 is nil until one is chosen, then exclusive" do
      assert {:ok, nil} = AI.default_model()

      provider = create_provider!()
      a = create_model!(provider)
      b = create_model!(provider)

      AI.make_default_model!(a)
      assert {:ok, %{id: id}} = AI.default_model()
      assert id == a.id

      AI.make_default_model!(b)
      assert {:ok, %{id: id}} = AI.default_model()
      assert id == b.id
      refute Ash.get!(AI.Model, a.id).default
    end

    test "list_models/0 loads the provider" do
      provider = create_provider!()
      create_model!(provider)

      assert [%{provider: %AI.Provider{}} | _] = AI.list_models!()
    end
  end

  describe "search providers" do
    test "tavily is the only kind for now and the key is encrypted" do
      sp =
        AI.create_search_provider!(%{
          name: "Tavily",
          slug: "tavily-#{uniq()}",
          kind: :tavily,
          api_key: "tvly-x"
        })

      assert sp.kind == :tavily
      assert sp.base_url == "https://api.tavily.com"
      assert %Ash.NotLoaded{} = sp.api_key
      refute sp.encrypted_api_key =~ "tvly-x"
      assert Ash.load!(sp, :api_key).api_key == "tvly-x"

      assert {:error, %Ash.Error.Invalid{}} =
               AI.create_search_provider(%{
                 name: "Bing",
                 slug: "bing-#{uniq()}",
                 kind: :bing,
                 api_key: "k"
               })
    end

    test "exactly one search provider is the default" do
      a =
        AI.create_search_provider!(%{name: "A", slug: "a-#{uniq()}", kind: :tavily, api_key: "k"})

      b =
        AI.create_search_provider!(%{name: "B", slug: "b-#{uniq()}", kind: :tavily, api_key: "k"})

      assert {:ok, nil} = AI.default_search_provider()
      AI.make_default_search_provider!(a)
      AI.make_default_search_provider!(b)

      assert {:ok, %{id: id}} = AI.default_search_provider()
      assert id == b.id
      refute Ash.get!(AI.SearchProvider, a.id).default
    end

    test "resolve_search_target/0" do
      assert {:error, :no_search_provider} = AI.resolve_search_target()

      keyless = AI.create_search_provider!(%{name: "K", slug: "k-#{uniq()}", kind: :tavily})
      AI.make_default_search_provider!(keyless)
      assert {:error, {:missing_api_key, slug}} = AI.resolve_search_target()
      assert slug == keyless.slug

      sp =
        AI.create_search_provider!(%{
          name: "T",
          slug: "t-#{uniq()}",
          kind: :tavily,
          api_key: "tvly-x"
        })

      AI.make_default_search_provider!(sp)

      assert {:ok,
              %AI.SearchTarget{
                kind: :tavily,
                api_key: "tvly-x",
                base_url: "https://api.tavily.com"
              }} =
               AI.resolve_search_target()
    end

    test "search_configured?/0 is true only with a default provider that has a key" do
      refute AI.search_configured?()

      sp =
        AI.create_search_provider!(%{
          name: "T",
          slug: "t-#{uniq()}",
          kind: :tavily,
          api_key: "tvly-x"
        })

      refute AI.search_configured?()
      AI.make_default_search_provider!(sp)
      assert AI.search_configured?()
    end
  end

  describe "agent tools (which registered tools a thread may get)" do
    test "list_tools/0 mirrors the registry into the DB: every tool present, new ones disabled" do
      tools = AI.list_tools!()
      names = Enum.map(tools, &{&1.namespace, &1.name})

      assert {"builtin", "echo"} in names
      assert {"builtin", "thread_status"} in names
      assert {"test", "echo"} in names
      assert Enum.all?(tools, &(&1.enabled == false))
      # description comes from the code, not the DB
      assert Enum.find(tools, &(&1.name == "thread_status")).description =~ "thread"
    end

    test "nothing is enabled by default, so nothing is injected" do
      assert AI.enabled_tool_names() == []
    end

    test "enable/disable by qualified name, kept across syncs" do
      assert {:ok, %{enabled: true}} = AI.enable_tool("builtin.thread_status")
      assert AI.enabled_tool_names() == ["builtin.thread_status"]

      # a re-sync (list) must not flip it back
      AI.list_tools!()
      assert AI.enabled_tool_names() == ["builtin.thread_status"]

      assert {:ok, %{enabled: false}} = AI.disable_tool("builtin.thread_status")
      assert AI.enabled_tool_names() == []
    end

    test "enabling an unregistered tool is an error" do
      assert {:error, :unknown_tool} = AI.enable_tool("nope.nothing")
    end

    test "a tool removed from the code disappears from the list" do
      AI.create_tool!(%{namespace: "gone", name: "tool"})
      refute Enum.any?(AI.list_tools!(), &(&1.namespace == "gone"))
    end
  end

  describe "web_search_mode/0" do
    test ":disabled when nothing is configured" do
      assert AI.web_search_mode() == :disabled
    end

    test ":disabled when the search provider has no key" do
      keyless = AI.create_search_provider!(%{name: "K", slug: "k-#{uniq()}", kind: :tavily})
      AI.make_default_search_provider!(keyless)
      assert AI.web_search_mode() == :disabled
    end

    test ":standalone when a search provider with a key is the default" do
      sp =
        AI.create_search_provider!(%{
          name: "T",
          slug: "t-#{uniq()}",
          kind: :tavily,
          api_key: "tvly"
        })

      AI.make_default_search_provider!(sp)
      assert AI.web_search_mode() == :standalone
    end

    test ":hosted when the default model's provider natively supports web search, even with Tavily configured" do
      sp =
        AI.create_search_provider!(%{
          name: "T",
          slug: "t-#{uniq()}",
          kind: :tavily,
          api_key: "tvly"
        })

      AI.make_default_search_provider!(sp)

      openai = create_provider!(%{slug: "openai-#{uniq()}", supports_hosted_web_search: true})
      AI.make_default_model!(create_model!(openai))

      assert AI.web_search_mode() == :hosted
    end

    test "a hosted-capable provider without a key falls back to what is left" do
      openai =
        create_provider!(%{
          slug: "openai-#{uniq()}",
          supports_hosted_web_search: true,
          api_key: nil
        })

      AI.make_default_model!(create_model!(openai))
      assert AI.web_search_mode() == :disabled
    end
  end

  describe "resolve_target/0" do
    test "combines the default model with its provider's credentials" do
      provider = create_provider!(%{base_url: "https://api.deepseek.com/v1", api_key: "sk-ds"})
      model = create_model!(provider, %{upstream_id: "deepseek-v4-pro", context_window: 64_000})
      AI.make_default_model!(model)

      assert {:ok,
              %AI.Target{
                model: "deepseek-v4-pro",
                base_url: "https://api.deepseek.com/v1",
                api_key: "sk-ds",
                context_window: 64_000,
                hosted_web_search?: false
              }} = AI.resolve_target()
    end

    test "errors when nothing is configured" do
      assert {:error, :no_default_model} = AI.resolve_target()
    end

    test "errors when the provider has no key" do
      provider = create_provider!(%{api_key: nil})
      model = create_model!(provider)
      AI.make_default_model!(model)

      assert {:error, {:missing_api_key, slug}} = AI.resolve_target()
      assert slug == provider.slug
    end
  end
end
