defmodule Longx.Tls.Dns do
  @moduledoc """
  Name lookups for HTTPS as the world sees them. In China a LAN's resolver
  is often a proxy's fake-ip DNS (Clash, mihomo, sing-box, Surge: every
  name answered with an address of its own in 198.18.0.0/15, the proxy
  mapping it back) — the page's "where does the name point" would read
  that address, and lego's propagation check would look the authoritative
  servers up through it. So `public_a/1` asks the public resolvers directly
  (`config :longx, Longx.Tls, public_dns:` — AliDNS and DNSPod's by
  default, over UDP), and AliDNS's DoH JSON (`doh_url:`) when UDP brings
  nothing back (a network that blocks outside DNS). `system_a/1` is this
  machine's own answer (`system_lookup:` in tests); `fake_ip?/1` tells a
  proxy's address.
  """

  @public_dns [{{223, 5, 5, 5}, 53}, {{119, 29, 29, 29}, 53}]
  @doh_url "https://223.5.5.5/resolve"
  @timeout 2_000

  @doc "The public resolvers as longx-cert takes them (`host:port`)."
  @spec public_resolvers() :: [String.t()]
  def public_resolvers do
    for {ip, port} <- config(:public_dns, @public_dns), do: "#{:inet.ntoa(ip)}:#{port}"
  end

  @doc "A proxy's fake-ip address: 198.18.0.0/15, the range Clash, mihomo, sing-box and Surge hand out."
  @spec fake_ip?(String.t()) :: boolean
  def fake_ip?(address) do
    case :inet.parse_address(String.to_charlist(address)) do
      {:ok, {198, b, _, _}} when b in [18, 19] -> true
      _ -> false
    end
  end

  @doc "The A records the public resolvers give (UDP, then DoH); [] when the name has none."
  @spec public_a(String.t()) :: [String.t()]
  def public_a(name) do
    case udp(name) do
      [] -> doh(name)
      found -> found
    end
  end

  @doc "What this machine's own resolver answers (two seconds at most)."
  @spec system_a(String.t()) :: [String.t()]
  def system_a(name) do
    case config(:system_lookup, nil) do
      lookup when is_function(lookup, 1) -> lookup.(name)
      {module, fun} -> apply(module, fun, [name])
      nil -> system(name)
    end
  end

  defp udp(name) do
    case config(:public_dns, @public_dns) do
      [] -> []
      nameservers -> udp(name, nameservers)
    end
  end

  defp udp(name, nameservers) do
    name
    |> String.to_charlist()
    |> :inet_res.lookup(:in, :a,
      nameservers: nameservers,
      timeout: config(:dns_timeout, @timeout),
      retry: 1
    )
    |> Enum.map(&(&1 |> :inet.ntoa() |> to_string()))
  end

  defp doh(name) do
    case config(:doh_url, @doh_url) do
      nil ->
        []

      url ->
        case Req.get(url,
               params: [name: name, type: 1],
               receive_timeout: config(:dns_timeout, @timeout),
               connect_options: [timeout: config(:dns_timeout, @timeout)],
               retry: false
             ) do
          {:ok, %Req.Response{status: 200, body: body}} -> doh_answers(body)
          _ -> []
        end
    end
  end

  # the JSON whatever its content type says (DoH servers differ)
  defp doh_answers(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> doh_answers(decoded)
      _ -> []
    end
  end

  defp doh_answers(%{"Answer" => answers}) when is_list(answers),
    do: for(%{"type" => 1, "data" => ip} <- answers, do: ip)

  defp doh_answers(_), do: []

  defp system(name) do
    task =
      Task.async(fn ->
        case :inet.getaddrs(String.to_charlist(name), :inet) do
          {:ok, ips} -> Enum.map(ips, &(&1 |> :inet.ntoa() |> to_string()))
          _ -> []
        end
      end)

    case Task.yield(task, @timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, ips} -> ips
      _ -> []
    end
  end

  defp config(key, default),
    do: Keyword.get(Application.get_env(:longx, Longx.Tls, []), key, default)
end
