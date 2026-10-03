defmodule Longx.Computer.ServiceTest do
  use Longx.DataCase, async: false
  alias Longx.Computer.Service

  test "remote URLs are allowed, credential-bearing and malformed URLs are rejected" do
    assert :ok = Service.validate_url("https://desktop.example:8443/mcp")
    assert :ok = Service.validate_url("http://192.0.2.1:7797/mcp")

    for url <- [
          "file:///mcp",
          "http://user:secret@host/mcp",
          "http://host/mcp?key=x",
          "http://host/other",
          "http://host/mcp#fragment"
        ] do
      assert {:error, :invalid_url} = Service.validate_url(url)
    end
  end

  test "settings expose presence only; changing target cannot reuse its key" do
    token = "test-only-computer-access-key-0123456789"
    assert {:ok, %{has_token: true}} = Service.save("http://127.0.0.1:7797/mcp", token)
    refute Jason.encode!(Service.settings()) =~ token
    assert {:ok, _} = Service.save("http://127.0.0.1:7797/mcp", "")
    assert {:error, :token_required} = Service.save("http://192.0.2.1:7797/mcp", "")
    assert {:ok, _} = Service.save("http://192.0.2.1:7797/mcp", token)
  end

  test "legacy endpoint migrates lazily, and removing local cannot resurrect it" do
    token = "legacy-fixture-key-012345678901234567890"

    assert {:ok, _} =
             Longx.System.put_setting(
               "computer_service",
               Jason.encode!(%{url: "http://127.0.0.1:7797/mcp", token: token})
             )

    assert {:ok, [%{id: "local", has_token: true}]} = Service.list()
    assert {:ok, ["local"]} = Service.resolve_ids(nil)
    assert {:ok, _} = Service.save("win", "Windows", "https://win.example/mcp", token)
    assert :ok = Service.put_alias("qa", ["win", "local"])
    assert :ok = Service.set_default("qa")
    assert {:ok, ["win", "local"]} = Service.resolve_ids(nil)
    assert :ok = Service.delete("local")
    assert {:ok, [%{id: "win"}]} = Service.list()
    assert {:ok, ["win"]} = Service.resolve_ids("qa")
    assert :ok = Service.delete("win")
    assert {:ok, []} = Service.list()
    assert {:error, _} = Service.resolve_ids(nil)
  end

  test "each key belongs to its own endpoint, duplicate services and invalid aliases are rejected" do
    token = "multi-fixture-key-012345678901234567890"
    assert {:ok, _} = Service.save("a", "Mac", "https://mac.example/mcp", token)
    assert {:error, :token_required} = Service.save("b", "Windows", "https://win.example/mcp", "")

    assert {:error, :duplicate_url} =
             Service.save("b", "Duplicate", "https://MAC.example/mcp", token)

    assert {:error, :invalid_alias} = Service.put_alias("bad alias", ["a"])
    assert {:error, :invalid_alias} = Service.put_alias("qa", ["missing"])
    assert {:error, :invalid_alias} = Service.put_alias("qa", ["a", "a"])
    assert {:error, :invalid_alias} = Service.set_default("missing")
    assert {:ok, devices} = Service.list()
    refute Jason.encode!(devices) =~ token
  end
end
