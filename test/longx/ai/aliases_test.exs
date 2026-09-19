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
             %{name: "ultra", models: [], builtin?: true},
             %{name: "pro"},
             %{name: "plus"}
           ] = Aliases.all()

    assert {:ok, ["model-a"]} = Aliases.resolve("ultra")
    assert :error = Aliases.resolve("model-a")
    assert :error = Aliases.resolve("nothing")

    assert {:ok, _} = Aliases.put("ultra", ["model-b", "model-a"])
    assert {:ok, ["model-b", "model-a"]} = Aliases.resolve("ultra")
    # a tier is known whatever the case it is written in
    assert {:ok, ["model-b", "model-a"]} = Aliases.resolve("Ultra")
    assert {:ok, _} = Aliases.put("PRO", ["model-a"])
    assert {:ok, ["model-a"]} = Aliases.resolve("pro")

    assert {:ok, _} = Aliases.put("青龙", ["model-b"])

    assert %{name: "青龙", models: ["model-b"], builtin?: false} =
             Enum.find(Aliases.all(), &(&1.name == "青龙"))

    assert :ok = Aliases.delete("青龙")
    assert :error = Aliases.resolve("青龙")
    # a tier is never deleted, only emptied
    assert {:error, _} = Aliases.delete("ultra")
    assert {:ok, _} = Aliases.put("ultra", [])
    assert {:ok, ["model-a"]} = Aliases.resolve("ultra")
  end

  test "an alias is validated: a name that is a model's slug, an unknown model, a bad name" do
    assert {:error, %{field: :name}} = Aliases.put("model-a", ["model-b"])
    assert {:error, %{field: :models}} = Aliases.put("x", ["nope"])
    assert {:error, %{field: :name}} = Aliases.put("has space", ["model-a"])
    assert {:error, %{field: :name}} = Aliases.put("", ["model-a"])
  end

  test "the rest of Longx.AI sees through an alias: targets in order, the first model's levels, the prompt's list" do
    {:ok, _} = Aliases.put("pro", ["model-b", "model-a"])
    assert {:ok, [%{model: "b"}, %{model: "a"}]} = AI.resolve_targets("pro")
    assert {:ok, [%{model: "a"}]} = AI.resolve_targets("model-a")
    assert {:ok, [%{model: "a"}]} = AI.resolve_targets(nil)
    assert {:error, {:unknown_model, "nope"}} = AI.resolve_targets("nope")
    # the first model answers for the alias
    assert {:ok, %{model: "b"}} = AI.resolve_target("pro")
    assert :ok = AI.check_effort("pro", "anything")
    assert {:error, {:unknown_effort, "mid"}} = AI.check_effort("ultra", "mid")
    assert {:ok, opts} = AI.thread_options("pro")
    assert opts[:model] == "pro"

    choices = AI.model_choices()

    assert [
             %{slug: "ultra", alias: ["model-a"]},
             %{slug: "pro", alias: ["model-b", "model-a"]},
             %{slug: "plus"} | models
           ] = choices

    assert Enum.map(models, & &1.slug) == ["model-a", "model-b"]
  end
end

defmodule Longx.AI.DefaultModelTest do
  @moduledoc "What runs when nobody picks: the default is a name — `plus` unless saved — over the base row."
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
        reasoning_levels: ["low", "high"],
        reasoning_effort: "low"
      })

    b =
      AI.create_model!(%{name: "B", upstream_id: "b", slug: "model-b", provider_id: provider.id})

    AI.make_default_model!(a)
    %{a: a, b: b}
  end

  test "unsaved, the default is the plus tier, which means the base row until plus is mapped; a saved tier, alias or slug takes over; the turn names what it runs on" do
    assert %{name: "plus", slug: "model-a", kind: :tier} = AI.default_model_info()
    assert {:ok, %{model: "a"}} = AI.resolve_target(nil)
    # what the turn says: asked for as plus, running on model-a at its default level
    assert {:ok, %{name: "plus", slug: "model-a", effort: "low"}} = AI.in_force(nil, nil)

    # plus mapped: the default follows it
    {:ok, _} = Aliases.put("plus", ["model-b", "model-a"])
    assert %{name: "plus", slug: "model-b"} = AI.default_model_info()
    assert {:ok, [%{model: "b"}, %{model: "a"}]} = AI.resolve_targets(nil)
    assert {:ok, %{name: "plus", slug: "model-b"}} = AI.in_force("longx", nil)

    # another tier, an alias, a concrete model (which also becomes the base row)
    assert {:ok, %{name: "ultra", kind: :tier, slug: "model-a"}} = AI.set_default_model("ultra")
    {:ok, _} = Aliases.put("青龙", ["model-b"])
    assert {:ok, %{name: "青龙", kind: :alias, slug: "model-b"}} = AI.set_default_model("青龙")

    assert {:ok, %{name: "model-b", kind: :model, slug: "model-b"}} =
             AI.set_default_model("model-b")

    assert {:ok, %AI.Model{slug: "model-b"}} = AI.default_model()
    assert {:ok, %{name: nil, slug: "model-b"}} = AI.in_force(nil, nil)

    # a name nobody has is refused; the prompt's list marks the default by its name
    assert {:error, message} = AI.set_default_model("nope")
    assert message =~ "nope"
    {:ok, _} = AI.set_default_model("plus")
    assert [%{slug: "plus", default?: true} | _] = Enum.filter(AI.model_choices(), & &1.default?)
  end
end
