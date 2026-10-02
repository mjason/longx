defmodule Longx.Computer.Service do
  @moduledoc "Connection settings for the independent Longx Computer app; never starts a Driver."
  alias Longx.Computer.MCP
  @key "computer_service"
  @default "http://127.0.0.1:7797/mcp"

  def settings do
    case stored() do
      {:ok, config} -> %{url: config["url"] || @default, has_token: is_binary(config["token"])}
      _ -> %{url: @default, has_token: false}
    end
  end

  def save(url, token) do
    with :ok <- validate_url(url),
         {:ok, old} <- stored(),
         {:ok, token} <- select_token(url, token, old),
         {:ok, _} <-
           Longx.System.put_setting(@key, Jason.encode!(%{"url" => url, "token" => token})) do
      {:ok, settings()}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :could_not_store_endpoint}
    end
  end

  def ensure(on_endpoint \\ fn _ -> :ok end) do
    with {:ok, endpoint} <- endpoint(),
         :ok <- on_endpoint.(endpoint),
         {:ok, endpoint, tools} <- MCP.initialize(endpoint) do
      :ok = on_endpoint.(endpoint)
      {:ok, endpoint, tools}
    end
  end

  def validate_url(url) when is_binary(url) do
    uri = URI.parse(url)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
         uri.path == "/mcp" and uri.userinfo == nil and uri.query == nil and
         uri.fragment == nil and (uri.port || 0) in 1..65535,
       do: :ok,
       else: {:error, :invalid_url}
  end

  def validate_url(_), do: {:error, :invalid_url}

  defp endpoint do
    case Application.get_env(:longx, Longx.Computer, [])[:endpoint] do
      %{url: url, token: token} = endpoint when is_binary(token) ->
        with :ok <- validate_url(url), do: {:ok, endpoint}

      nil ->
        with {:ok, %{"url" => url, "token" => token}} <- stored(),
             :ok <- validate_url(url) do
          {:ok, %{url: url, token: token}}
        else
          _ -> {:error, :not_configured}
        end

      _ ->
        {:error, :invalid_url}
    end
  end

  defp stored do
    case Longx.System.get_setting(@key, not_found_error?: false) do
      {:ok, nil} -> {:ok, %{}}
      {:ok, %{value: value}} when is_binary(value) -> Jason.decode(value)
      _ -> {:error, :could_not_read_endpoint}
    end
  end

  defp select_token(url, "", %{"url" => url, "token" => token}), do: {:ok, token}

  defp select_token(_url, token, _old) when is_binary(token) and byte_size(token) >= 32,
    do: {:ok, token}

  defp select_token(_, _, _), do: {:error, :token_required}
end
