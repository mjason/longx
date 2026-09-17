defmodule Longx.AI.AliasesTest do
  use Longx.DataCase, async: false

  alias Longx.AI
  alias Longx.AI.Aliases

  setup do
    Ash.bulk_destroy!(Longx.System.Setting, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(AI.Model, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(AI.Provider, :destroy, %{}, authorize?: false)
    n = System.unique_integer([:positive])

    provider =
      AI.create_provider!(%{
        name: "Up #{n}",
        slug: "up-#{n}",
        base_url: "http://localhost:1/v1",
        api_key: "k"
      })

    a =
      AI.create_model!(%{
        name: "A",
        upstream_id: "a",
        slug: "model-a",
        provider_id: provider.id,
        reasoning_levels: ["low", "high"]
      })

    b =
      AI.create_model!(%{name: "B", upstream_id: "b", slug: "model-b", provider_id: provider.id})

    AI.make_default_model!(a)
    %{a: a, b: b}
  end

  test "the three tiers always exist; unset they mean the default model; a custom alias can be added and removed" do
    assert [
             %{name: "flagship", models: [], builtin?: true},
             %{name: "advanced"},
             %{name: "standard"}
           ] = Aliases.all()

    assert {:ok, ["model-a"]} = Aliases.resolve("flagship")
    assert :error = Aliases.resolve("model-a")
    assert :error = Aliases.resolve("nothing")

    assert {:ok, _} = Aliases.put("flagship", ["model-b", "model-a"])
    assert {:ok, ["model-b", "model-a"]} = Aliases.resolve("flagship")

    assert {:ok, _} = Aliases.put("青龙", ["model-b"])

    assert %{name: "青龙", models: ["model-b"], builtin?: false} =
             Enum.find(Aliases.all(), &(&1.name == "青龙"))

    assert :ok = Aliases.delete("青龙")
    assert :error = Aliases.resolve("青龙")
    # a tier is never deleted, only emptied
    assert {:error, _} = Aliases.delete("flagship")
    assert {:ok, _} = Aliases.put("flagship", [])
    assert {:ok, ["model-a"]} = Aliases.resolve("flagship")
  end

  test "an alias is validated: a name that is a model's slug, an unknown model, a bad name" do
    assert {:error, %{field: :name}} = Aliases.put("model-a", ["model-b"])
    assert {:error, %{field: :models}} = Aliases.put("x", ["nope"])
    assert {:error, %{field: :name}} = Aliases.put("has space", ["model-a"])
    assert {:error, %{field: :name}} = Aliases.put("", ["model-a"])
  end

  test "the rest of Longx.AI sees through an alias: targets in order, the first model's levels, the prompt's list" do
    {:ok, _} = Aliases.put("advanced", ["model-b", "model-a"])
    assert {:ok, [%{model: "b"}, %{model: "a"}]} = AI.resolve_targets("advanced")
    assert {:ok, [%{model: "a"}]} = AI.resolve_targets("model-a")
    assert {:ok, [%{model: "a"}]} = AI.resolve_targets(nil)
    assert {:error, {:unknown_model, "nope"}} = AI.resolve_targets("nope")
    # the first model answers for the alias
    assert {:ok, %{model: "b"}} = AI.resolve_target("advanced")
    assert :ok = AI.check_effort("advanced", "anything")
    assert {:error, {:unknown_effort, "mid"}} = AI.check_effort("flagship", "mid")
    assert {:ok, opts} = AI.thread_options("advanced")
    assert opts[:model] == "advanced"

    choices = AI.model_choices()

    assert [
             %{slug: "flagship", alias: ["model-a"]},
             %{slug: "advanced", alias: ["model-b", "model-a"]},
             %{slug: "standard"} | models
           ] = choices

    assert Enum.map(models, & &1.slug) == ["model-a", "model-b"]
  end
end
