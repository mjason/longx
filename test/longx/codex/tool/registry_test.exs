defmodule Longx.Codex.Tool.RegistryTest do
  # mutates the global registry (reload! with config) — must not overlap other tests
  use ExUnit.Case, async: false

  alias Longx.Codex.Tool.{Context, Registry}

  test "tools are discovered by behaviour: builtins and test tools alike" do
    names = Registry.all() |> Enum.map(&{&1.namespace, &1.name}) |> MapSet.new()

    assert MapSet.member?(names, {"builtin", "echo"})
    assert MapSet.member?(names, {"builtin", "thread_status"})
    assert MapSet.member?(names, {"test", "echo"})
  end

  test "fetch/2 resolves by namespace + name; unknown is :error" do
    assert {:ok, %{module: Longx.Test.Tools.Echo, timeout: 30_000}} =
             Registry.fetch("test", "echo")

    assert {:ok, %{module: Longx.Test.Tools.Slow, timeout: 200}} = Registry.fetch("test", "slow")
    assert :error = Registry.fetch("test", "nope")
    assert :error = Registry.fetch("nope", "echo")
  end

  test "optional callbacks get defaults" do
    {:ok, echo} = Registry.fetch("test", "echo")
    assert echo.timeout == 30_000
    assert echo.available?.(%Context{}) == true
  end

  test "specs/1 groups available tools into codex dynamicTools namespaces" do
    specs = Registry.specs(%Context{cwd: nil})
    test_ns = Enum.find(specs, &(&1["name"] == "test"))

    assert test_ns["type"] == "namespace"
    assert is_binary(test_ns["description"])
    tools = Enum.map(test_ns["tools"], & &1["name"])
    assert "echo" in tools
    # available?/1 is honoured: contextual needs a cwd
    refute "contextual" in tools

    assert "contextual" in Enum.map(
             Enum.find(Registry.specs(%Context{cwd: "/x"}), &(&1["name"] == "test"))["tools"],
             & &1["name"]
           )

    [echo] = Enum.filter(test_ns["tools"], &(&1["name"] == "echo"))

    assert %{
             "type" => "function",
             "description" => "Returns the given message.",
             "inputSchema" => %{"type" => "object"}
           } = echo
  end

  test "specs/2 only: accepts qualified names as well as modules" do
    [ns] = Registry.specs(%Context{}, only: ["test.echo"])
    assert ns["name"] == "test"
    assert Enum.map(ns["tools"], & &1["name"]) == ["echo"]

    [ns] = Registry.specs(%Context{}, only: [Longx.Tools.Builtin.Echo])
    assert ns["name"] == "builtin"

    assert Registry.specs(%Context{}, only: ["nope.nope"]) == []
  end

  test "disabled tools (config) are neither listed nor callable" do
    with_config([disabled: ["test.echo"]], fn ->
      refute Enum.any?(Registry.all(), &(&1.namespace == "test" and &1.name == "echo"))
      assert :error = Registry.fetch("test", "echo")
    end)
  end

  test "extra tools (config) from anywhere are registered" do
    with_config([extra: [Longx.Codex.Tool.RegistryTest.External]], fn ->
      assert {:ok, %{module: __MODULE__.External}} = Registry.fetch("ext", "hello")
    end)
  end

  test "two tools with the same namespace and name is a startup error" do
    assert_raise ArgumentError, ~r/duplicate tool test\.echo/, fn ->
      with_config([extra: [Longx.Codex.Tool.RegistryTest.Duplicate]], fn -> Registry.all() end)
    end
  end

  # reload!/0 may itself raise (duplicate tools), so it must be inside the try
  # or the config leaks into every later test
  defp with_config(config, fun) do
    previous = Application.get_env(:longx, Longx.Codex.Tool, [])
    Application.put_env(:longx, Longx.Codex.Tool, config)

    try do
      Registry.reload!()
      fun.()
    after
      Application.put_env(:longx, Longx.Codex.Tool, previous)
      Registry.reload!()
    end
  end

  defmodule External do
    @behaviour Longx.Codex.Tool
    def name, do: "hello"
    def namespace, do: "ext"
    def description, do: "External tool."
    def input_schema, do: %{"type" => "object"}
    def call(_a, _c), do: {:ok, "hi"}
  end

  defmodule Duplicate do
    @behaviour Longx.Codex.Tool
    def name, do: "echo"
    def namespace, do: "test"
    def description, do: "dup"
    def input_schema, do: %{"type" => "object"}
    def call(_a, _c), do: {:ok, "dup"}
  end
end
