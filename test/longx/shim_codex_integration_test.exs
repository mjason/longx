defmodule Longx.ShimCodexIntegrationTest do
  @moduledoc """
  Drives the bundled `codex-app-server` (see `Longx.Codex.Runtime`) through
  `Longx.Shim`. Excluded by default; needs `mix codex.fetch` first, then run
  with `mix test --include integration`.
  """
  use ExUnit.Case, async: false

  alias Longx.Codex.Runtime
  alias Longx.Shim

  @moduletag :integration

  test "the bundled binary is the pinned version" do
    {:ok, exe} = Runtime.executable()
    assert {"codex-app-server #{Runtime.version()}\n", 0} == System.cmd(exe, ["--version"])
  end

  test "initialize round-trip over stdio JSON-RPC, then clean shutdown" do
    {:ok, exe} = Runtime.executable()
    {:ok, shim} = Shim.start_link([exe])

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
