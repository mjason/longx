defmodule Longx.Test.Tools.Echo do
  @moduledoc "Test tool: returns its arguments. Namespace `test` so it never collides with builtins."
  @behaviour Longx.Codex.Tool

  @impl true
  def name, do: "echo"
  @impl true
  def namespace, do: "test"
  @impl true
  def description, do: "Returns the given message."
  @impl true
  def input_schema,
    do: %{
      "type" => "object",
      "properties" => %{"message" => %{"type" => "string"}},
      "required" => ["message"],
      "additionalProperties" => false
    }

  @impl true
  def call(%{"message" => message}, _ctx), do: {:ok, "echo: " <> message}
end
