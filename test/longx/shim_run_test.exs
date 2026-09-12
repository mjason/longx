defmodule Longx.ShimRunTest do
  use ExUnit.Case, async: true

  alias Longx.Shim

  test "run/2 collects stdout and stderr separately and returns the status" do
    assert {:ok, %{status: 0, stdout: "out\n", stderr: "err\n"}} =
             Shim.run(["sh", "-c", "echo out; echo err 1>&2"])

    assert {:ok, %{status: 3}} = Shim.run(["sh", "-c", "exit 3"])
  end

  test "run/2 feeds :input and closes stdin" do
    assert {:ok, %{status: 0, stdout: "abc"}} = Shim.run(["cat"], input: "abc")
  end

  test "run/2 drains both streams even when the child floods one of them" do
    {:ok, %{status: 0, stdout: out, stderr: err}} =
      Shim.run(["sh", "-c", "yes | head -c 300000; yes e | head -c 300000 1>&2"])

    assert byte_size(out) == 300_000
    assert byte_size(err) == 300_000
  end

  test "run/2 kills the tree on timeout" do
    assert {:error, :timeout} = Shim.run(["sh", "-c", "sleep 30; echo never"], timeout: 300)
  end
end
