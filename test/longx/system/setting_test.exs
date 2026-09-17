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

  test "a setting the page edits can be changed, not only set once (the GitHub token)" do
    assert :ok = Longx.Upgrade.set_github_token("ghp_one")
    assert Longx.Upgrade.github_token() == "ghp_one"
    assert :ok = Longx.Upgrade.set_github_token("ghp_two")
    assert Longx.Upgrade.github_token() == "ghp_two"
    assert :ok = Longx.Upgrade.set_github_token(nil)
    assert Longx.Upgrade.github_token() == nil
  end
end
