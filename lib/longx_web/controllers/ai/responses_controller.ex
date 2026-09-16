defmodule LongxWeb.AI.ResponsesController do
  @moduledoc """
  `POST /ai/v1/responses` — the endpoint the bundled codex-app-server is
  pointed at. Resolves the configured upstream and relays the stream.
  """

  use LongxWeb, :controller

  alias Longx.AI
  alias Longx.AI.Gateway
  alias Longx.AI.Gateway.Log

  # every request is remembered (Gateway.Log): what codex asked for and what
  # came of it, refused ones included
  def create(conn, _params) do
    body = conn.body_params
    resolved = AI.resolve_target(model_name(body))
    id = Log.begin(body, log_target(resolved))

    conn =
      with {:ok, target} <- resolved,
           {:ok, upstream} <- Gateway.prepare(body, target) do
        Gateway.stream(upstream, conn)
      else
        {:error, :invalid_request} ->
          refuse(conn, 400, "body is not a Responses API request")

        {:error, {:unknown_model, name}} ->
          refuse(
            conn,
            400,
            "unknown model #{inspect(name)} — not a model slug configured in Longx"
          )

        {:error, :no_default_model} ->
          refuse(conn, 503, "no default model configured — pick one in Longx settings")

        {:error, {:missing_api_key, slug}} ->
          refuse(conn, 503, "provider #{slug} has no API key configured")
      end

    Log.finish(id, %{status: conn.status, error: conn.private[:longx_gateway_error]})
    conn
  end

  defp refuse(conn, status, message) do
    conn
    |> Plug.Conn.put_private(:longx_gateway_error, message)
    |> Gateway.error(status, message)
  end

  defp log_target({:ok, %AI.Target{model: upstream_id, provider_slug: slug}}),
    do: %{upstream_id: upstream_id, provider: slug}

  defp log_target(_), do: nil

  defp model_name(%{"model" => name}) when is_binary(name), do: name
  defp model_name(_), do: nil
end
