defmodule Longx.Codex.Message do
  @moduledoc """
  Builds and classifies app-server JSON-RPC messages. Codex omits the
  `"jsonrpc"` member; so do we.
  """

  alias Longx.Codex.Error

  @type classified ::
          {:server_request, id :: term, method :: String.t(), params :: map}
          | {:response, id :: term, {:ok, term} | {:error, Error.t()}}
          | {:notification, method :: String.t(), params :: map}
          | {:unknown, term}

  @spec request(term, String.t(), term) :: map
  def request(id, method, params), do: %{"id" => id, "method" => method, "params" => params}

  @spec notification(String.t(), term) :: map
  def notification(method, params), do: %{"method" => method, "params" => params}

  @spec response(term, term) :: map
  def response(id, result), do: %{"id" => id, "result" => result}

  @spec error_response(term, integer, String.t()) :: map
  def error_response(id, code, message),
    do: %{"id" => id, "error" => %{"code" => code, "message" => message}}

  @doc "One JSON line, newline-terminated."
  @spec encode(map) :: iodata
  def encode(message), do: [Jason.encode_to_iodata!(message), ?\n]

  @spec classify(term) :: classified
  def classify(%{"id" => id, "method" => method} = msg),
    do: {:server_request, id, method, Map.get(msg, "params") || %{}}

  def classify(%{"id" => id, "error" => %{"code" => code, "message" => message} = error}),
    do: {:response, id, {:error, %Error{code: code, message: message, data: error["data"]}}}

  def classify(%{"id" => id, "result" => result}), do: {:response, id, {:ok, result}}

  def classify(%{"method" => method} = msg),
    do: {:notification, method, Map.get(msg, "params") || %{}}

  def classify(other), do: {:unknown, other}
end
