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
end
