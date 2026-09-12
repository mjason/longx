defmodule LongxWeb.AI.ResponsesController do
  @moduledoc """
  `POST /ai/v1/responses` — the endpoint the bundled codex-app-server is
  pointed at. Resolves the configured upstream and relays the stream.
  """

  use LongxWeb, :controller

  alias Longx.AI
  alias Longx.AI.Gateway

  def create(conn, _params) do
    with {:ok, target} <- AI.resolve_target(model_name(conn.body_params)),
         {:ok, upstream} <- Gateway.prepare(conn.body_params, target) do
      Gateway.stream(upstream, conn)
    else
      {:error, :invalid_request} ->
        Gateway.error(conn, 400, "body is not a Responses API request")

      {:error, {:unknown_model, name}} ->
        Gateway.error(
          conn,
          400,
          "unknown model #{inspect(name)} — not a model slug configured in Longx"
        )

      {:error, :no_default_model} ->
        Gateway.error(conn, 503, "no default model configured — pick one in Longx settings")

      {:error, {:missing_api_key, slug}} ->
        Gateway.error(conn, 503, "provider #{slug} has no API key configured")
    end
  end

  defp model_name(%{"model" => name}) when is_binary(name), do: name
  defp model_name(_), do: nil
end
