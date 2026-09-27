defmodule Longx.Chrome.Policy do
  @moduledoc """
  Where the agent may go in the person's browser: the browser row's
  `origins` (`allow` / `deny` per origin, for good) and a session's own
  answers (this turn, this session). `check/3` says `:allow`, `:deny`, or
  `:ask` — the session then asks the person (`Longx.Agent.ask/2`) and
  remembers the answer where they said to.
  """

  @doc "The origin of a URL as the map keys it: scheme, host, non-default port. `about:blank` is always fine."
  @spec origin(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def origin(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: scheme, host: host, port: port}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        default = if scheme == "https", do: 443, else: 80
        port_part = if port in [nil, default], do: "", else: ":#{port}"
        {:ok, "#{scheme}://#{String.downcase(host)}#{port_part}"}

      _ ->
        {:error, "not an http(s) URL: #{url}"}
    end
  end

  @spec blank?(String.t()) :: boolean
  def blank?(url), do: String.trim(url) in ["about:blank", ""]

  @doc "The verdict for a URL given the browser's origins and the session's own allowances."
  @spec check(String.t(), map, map) :: {:allow | :deny | :ask, String.t()} | {:error, String.t()}
  def check(url, browser_origins, session_origins)
      when is_map(browser_origins) and is_map(session_origins) do
    with {:ok, origin} <- origin(url) do
      case Map.get(browser_origins, origin) || Map.get(session_origins, origin) do
        %{"access" => "allow"} -> {:allow, origin}
        %{"access" => "deny"} -> {:deny, origin}
        _ -> {:ask, origin}
      end
    end
  end
end
