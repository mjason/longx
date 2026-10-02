defmodule Longx.Computer.MCP do
  @moduledoc """
  Longx Computer's HTTP MCP client. Sessions survive TCP changes, but not
  service restarts. No retries, redirects or browser-origin headers.
  """

  @protocol "2025-06-18"

  def request(endpoint, method, params \\ %{}, opts \\ []) do
    id = System.unique_integer([:positive])
    body = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

    case Req.post(endpoint.url,
           json: body,
           headers:
             [
               {"authorization", "Bearer " <> endpoint.token},
               {"mcp-protocol-version", @protocol}
             ] ++ session_headers(endpoint),
           finch: [name: Longx.Computer.Finch],
           retry: false,
           redirect: false,
           receive_timeout: Keyword.get(opts, :timeout, 30_000)
         ) do
      {:ok, %{status: 200, body: %{"id" => ^id, "result" => result}, headers: headers}} ->
        result = result |> Jason.encode!() |> scrub(endpoint.token) |> Jason.decode!()

        if Keyword.get(opts, :initialize, false),
          do: {:ok, result, List.first(headers["mcp-session-id"] || [])},
          else: {:ok, result}

      {:ok, %{status: 200, body: %{"error" => %{"message" => message}}}} ->
        {:error, {:protocol, scrub(message, endpoint.token)}}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, _reason} ->
        # Never return a Req request/exception that might include auth headers.
        {:error, :transport_lost}
    end
  end

  def initialize(endpoint) do
    with {:ok, %{"protocolVersion" => @protocol}, session} <-
           request(
             endpoint,
             "initialize",
             %{
               "protocolVersion" => @protocol,
               "capabilities" => %{},
               "clientInfo" => %{"name" => "Longx", "version" => "1"}
             },
             initialize: true
           ),
         true <- is_binary(session) and session != "",
         endpoint = Map.put(endpoint, :session, session),
         :ok <- initialized(endpoint),
         {:ok, %{"tools" => tools}} <- request(endpoint, "tools/list") do
      {:ok, endpoint, tools}
    else
      {:ok, _} -> {:error, :unsupported_protocol}
      false -> {:error, :missing_session}
      error -> error
    end
  end

  def call(endpoint, name, args),
    do: request(endpoint, "tools/call", %{"name" => name, "arguments" => args})

  defp initialized(endpoint) do
    case Req.post(endpoint.url,
           json: %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
           headers: [{"authorization", "Bearer " <> endpoint.token}] ++ session_headers(endpoint),
           finch: [name: Longx.Computer.Finch],
           retry: false,
           redirect: false,
           receive_timeout: 5_000
         ) do
      {:ok, %{status: status}} when status in [200, 202, 204] -> :ok
      _ -> {:error, :transport_lost}
    end
  end

  def close(%{session: _} = endpoint) do
    Req.delete(endpoint.url,
      headers: [{"authorization", "Bearer " <> endpoint.token}] ++ session_headers(endpoint),
      finch: [name: Longx.Computer.Finch],
      retry: false,
      redirect: false,
      receive_timeout: 2_000
    )

    :ok
  rescue
    _ -> :ok
  end

  def close(_), do: :ok

  defp session_headers(%{session: session}), do: [{"mcp-session-id", session}]
  defp session_headers(_), do: []
  defp scrub(message, token), do: String.replace(message, token, "[redacted]")
end
