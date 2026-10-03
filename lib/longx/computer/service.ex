defmodule Longx.Computer.Service do
  @moduledoc "Connection settings for the independent Longx Computer app; never starts a Driver."
  alias Longx.Computer.MCP
  @key "computer_service"
  @default "http://127.0.0.1:7797/mcp"
  @multi_key "computer_services"

  def settings(id \\ "local") do
    case stored(id) do
      {:ok, config} -> %{url: config["url"] || @default, has_token: is_binary(config["token"])}
      _ -> %{url: @default, has_token: false}
    end
  end

  def save(url, token), do: save("local", "Local", url, token)

  def save(id, name, url, token) do
    locked(fn ->
      with :ok <- validate_url(url),
           true <- is_binary(id) and id != "" and is_binary(name) and String.trim(name) != "",
           {:ok, config} <- configuration(),
           :ok <- unique_url(config, id, url),
           old = config["computers"][id] || %{},
           {:ok, token} <- select_token(url, token, old),
           {:ok, _} <-
             persist(
               put_in(config, ["computers", id], %{"name" => name, "url" => url, "token" => token})
             ) do
        {:ok, settings(id)}
      else
        {:error, reason} when is_atom(reason) -> {:error, reason}
        _ -> {:error, :could_not_store_endpoint}
      end
    end)
  end

  def ensure(on_endpoint \\ fn _ -> :ok end), do: ensure("local", on_endpoint)

  def ensure(id, on_endpoint) do
    with {:ok, endpoint} <- endpoint(id),
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

  defp endpoint(id) do
    overrides = Application.get_env(:longx, Longx.Computer, [])

    override =
      if id == "local", do: overrides[:endpoint], else: (overrides[:endpoints] || %{})[id]

    case override do
      %{url: url, token: token} = endpoint when is_binary(token) ->
        with :ok <- validate_url(url), do: {:ok, endpoint}

      nil ->
        with {:ok, %{"url" => url, "token" => token}} when is_binary(token) <- stored(id),
             :ok <- validate_url(url) do
          {:ok, %{url: url, token: token}}
        else
          _ -> {:error, :not_configured}
        end

      _ ->
        {:error, :invalid_url}
    end
  end

  defp legacy do
    case Longx.System.get_setting(@key, not_found_error?: false) do
      {:ok, nil} -> {:ok, %{}}
      {:ok, %{value: value}} when is_binary(value) -> Jason.decode(value)
      _ -> {:error, :could_not_read_endpoint}
    end
  end

  defp stored(id) do
    with {:ok, config} <- configuration(), do: {:ok, config["computers"][id] || %{}}
  end

  def configuration do
    case Longx.System.get_setting(@multi_key, not_found_error?: false) do
      {:ok, nil} ->
        with {:ok, old} <- legacy() do
          {:ok,
           %{
             "computers" => %{"local" => Map.put(old, "name", "Local")},
             "aliases" => %{"local" => ["local"]},
             "default" => "local"
           }}
        end

      {:ok, %{value: value}} ->
        Jason.decode(value)

      _ ->
        {:error, :could_not_read_endpoint}
    end
  end

  def list do
    with {:ok, config} <- configuration() do
      {:ok,
       config["computers"]
       |> Enum.map(fn {id, row} ->
         Map.merge(settings(id), %{id: id, name: row["name"]})
       end)
       |> Enum.sort_by(& &1.name)}
    end
  end

  def aliases do
    with {:ok, config} <- configuration() do
      {:ok,
       %{
         default: config["default"],
         aliases:
           config["aliases"]
           |> Enum.map(fn {name, ids} ->
             %{name: name, computers: ids}
           end)
           |> Enum.sort_by(& &1.name)
       }}
    end
  end

  def resolve_ids(name) do
    with {:ok, config} <- configuration(),
         name = name || config["default"],
         ids when is_list(ids) and ids != [] <- config["aliases"][name] do
      {:ok, ids}
    else
      _ -> {:error, "Select a computer alias in Settings first"}
    end
  end

  def put_alias(name, ids) do
    change(fn config ->
      if is_binary(name) and Regex.match?(~r/^[\p{L}\p{N}_-]+$/u, name) and
           ids != [] and length(Enum.uniq(ids)) == length(ids) and
           Enum.all?(ids, &Map.has_key?(config["computers"], &1)) do
        {:ok, put_in(config, ["aliases", name], ids)}
      else
        {:error, :invalid_alias}
      end
    end)
  end

  def delete_alias(name) do
    change(fn config ->
      config = %{config | "aliases" => Map.delete(config["aliases"], name)}
      {:ok, if(config["default"] == name, do: %{config | "default" => nil}, else: config)}
    end)
  end

  def set_default(name) do
    change(fn config ->
      if is_nil(name) or Map.has_key?(config["aliases"], name),
        do: {:ok, %{config | "default" => name}},
        else: {:error, :invalid_alias}
    end)
  end

  def delete(id) do
    change(fn config ->
      aliases =
        for {name, ids} <- config["aliases"],
            kept = Enum.reject(ids, &(&1 == id)),
            kept != [],
            into: %{},
            do: {name, kept}

      {:ok,
       %{
         config
         | "computers" => Map.delete(config["computers"], id),
           "aliases" => aliases,
           "default" => if(Map.has_key?(aliases, config["default"]), do: config["default"])
       }}
    end)
  end

  defp change(fun) do
    locked(fn ->
      with {:ok, config} <- configuration(),
           {:ok, updated} <- fun.(config),
           {:ok, _} <- persist(updated),
           do: :ok
    end)
  end

  defp persist(config), do: Longx.System.put_setting(@multi_key, Jason.encode!(config))
  defp locked(fun), do: :global.trans({{__MODULE__, :settings}, self()}, fun)

  defp unique_url(config, id, url) do
    normalize = fn value ->
      uri = URI.parse(value)
      URI.to_string(%{uri | host: String.downcase(uri.host)})
    end

    if Enum.any?(config["computers"], fn {other, row} ->
         other != id and is_binary(row["url"]) and normalize.(row["url"]) == normalize.(url)
       end), do: {:error, :duplicate_url}, else: :ok
  end

  defp select_token(url, "", %{"url" => url, "token" => token}), do: {:ok, token}

  defp select_token(_url, token, _old) when is_binary(token) and byte_size(token) >= 32,
    do: {:ok, token}

  defp select_token(_, _, _), do: {:error, :token_required}
end
