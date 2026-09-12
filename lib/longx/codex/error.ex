defmodule Longx.Codex.Error do
  @moduledoc "A JSON-RPC error returned by the app-server."

  defexception [:code, :message, :data]

  @type t :: %__MODULE__{code: integer, message: String.t(), data: term}

  @impl true
  def message(%__MODULE__{code: code, message: message}), do: "codex error #{code}: #{message}"
end
