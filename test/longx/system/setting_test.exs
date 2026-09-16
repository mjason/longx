defmodule Longx.System.SettingTest do
  # the encrypted key → value store behind the settings page
  use Longx.DataCase, async: false

  alias Longx.System

  test "a key put twice holds the second value (the upsert must name the ciphertext column)" do
    System.put_setting!("probe", "a")
    System.put_setting!("probe", "b")
    assert {:ok, %{value: "b"}} = System.get_setting("probe")
    assert {:ok, %{value: "b"}} = System.get_setting("probe")
    {:ok, s} = System.get_setting("probe")
    System.delete_setting!(s)
    assert {:error, _} = System.get_setting("probe")
  end

  test "the review model can be changed, not only set once" do
    model = Longx.AI.default_model!()
    assert :ok = Longx.AI.set_review_model(model.slug, nil)
    assert %{model: %{slug: slug}} = Longx.AI.review_model()
    assert slug == model.slug
    # a second choice replaces the first
    other = Longx.AI.list_models!() |> Enum.find(&(&1.slug != model.slug))

    if other do
      assert :ok = Longx.AI.set_review_model(other.slug, nil)
      assert %{model: %{slug: slug2}} = Longx.AI.review_model()
      assert slug2 == other.slug
    end

    assert :ok = Longx.AI.set_review_model(nil, nil)
  end
end
