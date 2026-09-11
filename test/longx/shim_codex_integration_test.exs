defmodule Longx.ShimCodexIntegrationTest do
  @moduledoc """
  Drives the real `codex app-server` through `Longx.Shim`. Excluded by default;
  run with `mix test --include integration`.
  """
  use ExUnit.Case, async: false

  alias Longx.Shim

  @moduletag :integration

  test "initialize round-trip over stdio JSON-RPC, then clean shutdown" do
    {:ok, shim} = Shim.start_link(["codex", "app-server"])

    request = %{
      id: 1,
      method: "initialize",
      params: %{clientInfo: %{name: "longx", title: "Longx", version: "0.1.0"}}
    }

    :ok = Shim.write(shim, [Jason.encode!(request), "\n"])

    {:ok, chunk} = Shim.read(shim, Longx.Shim.Proto.max_chunk(), 15_000)
    [line | _] = String.split(chunk, "\n", trim: true)
    assert %{"id" => 1, "result" => %{"platformFamily" => _}} = Jason.decode!(line)

    :ok = Shim.kill(shim, 2_000)
    assert {:ok, status} = Shim.await_exit(shim, 5_000)
    assert is_integer(status)
  end
end
