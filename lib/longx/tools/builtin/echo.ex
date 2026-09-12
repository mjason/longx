defmodule Longx.Tools.Builtin.Echo do
  @moduledoc "Returns its input. Exists to prove the tool path end to end and as the smallest example."
  @behaviour Longx.Codex.Tool

  @impl true
  def name, do: "echo"

  @impl true
  def namespace, do: "builtin"

  @impl true
  def description,
    do: "Returns the given message unchanged. Only useful for testing the tool connection."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{"message" => %{"type" => "string", "description" => "Text to echo back."}},
      "required" => ["message"],
      "additionalProperties" => false
    }
  end

  @impl true
  def call(%{"message" => message}, _ctx), do: {:ok, message}
end
