defmodule Longx.AI.ModelImportTest do
  use Longx.DataCase, async: false
  alias Longx.AI

  setup do
    Ash.bulk_destroy!(AI.Model, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(AI.Provider, :destroy, %{}, authorize?: false)
    :ok
  end

  defp provider(slug),
    do: AI.create_provider!(%{slug: slug, name: slug, base_url: "https://example.test/v1"})

  defp import_model(provider, upstream, extra \\ %{}),
    do:
      AI.import_discovered_model(
        Map.merge(%{provider_id: provider.id, upstream_id: upstream, name: upstream}, extra)
      )

  test "discovery imports the same upstream models from another provider without stealing names" do
    ls = provider("ls")
    chatgpt = provider("chatgpt")

    for upstream <- ["gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra"] do
      original = AI.create_model!(%{provider_id: ls.id, upstream_id: upstream, name: upstream})
      assert {:ok, added} = import_model(chatgpt, upstream)
      assert added.slug == "chatgpt-#{upstream}"
      assert added.provider_id == chatgpt.id
      assert AI.get_model_by_slug!(upstream).id == original.id
      assert {:ok, same} = import_model(chatgpt, upstream)
      assert same.id == added.id
    end

    assert length(AI.list_models!()) == 6
  end

  test "implicit names handle occupied prefixes, explicit names still report conflicts" do
    ls = provider("ls")
    other = provider("other")

    for slug <- ["model", "other-model"] do
      AI.create_model!(%{provider_id: ls.id, upstream_id: slug, name: slug, slug: slug})
    end

    assert {:ok, model} = import_model(other, "model")
    assert model.slug == "other-model-2"

    assert {:error, _} =
             AI.create_model(%{
               provider_id: other.id,
               upstream_id: "another",
               name: "another",
               slug: "model"
             })

    assert {:error, _} =
             AI.create_model(%{provider_id: other.id, upstream_id: "longx", name: "reserved"})
  end

  test "retry preserves an existing alias and its edited configuration" do
    p = provider("p")

    old =
      AI.create_model!(%{
        provider_id: p.id,
        upstream_id: "remote",
        slug: "my-local-name",
        name: "My model",
        context_window: 12345,
        reasoning_levels: ["low"],
        reasoning_effort: "low"
      })

    assert {:ok, same} = import_model(p, "remote", %{name: "Different", context_window: 99999})
    assert same.id == old.id
    assert same.slug == "my-local-name"
    assert same.name == "My model"
    assert same.context_window == 12345
  end

  test "concurrent imports on one provider are idempotent; providers keep separate rows" do
    a = provider("a")
    b = provider("b")
    tasks = for p <- [a, a, b], do: Task.async(fn -> import_model(p, "shared") end)
    assert [{:ok, a1}, {:ok, a2}, {:ok, b1}] = Enum.map(tasks, &Task.await/1)
    assert a1.id == a2.id
    refute a1.id == b1.id
    refute a1.slug == b1.slug
    assert length(AI.list_models!()) == 2
  end
end
