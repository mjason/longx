defmodule Longx.AITest do
  use Longx.DataCase, async: false

  alias Longx.AI

  # `mix test` runs the seeds, so the sandbox starts with the DeepSeek rows;
  # these tests reason about an empty catalogue.
  setup do
    Ash.bulk_destroy!(AI.Model, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(AI.Provider, :destroy, %{}, authorize?: false)
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
                context_window: 64_000
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
