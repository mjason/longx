defmodule Longx.Tls do
  @moduledoc """
  HTTPS for Longx itself, with a certificate every browser trusts even on a
  LAN: the ACME DNS-01 challenge only needs a TXT record in the domain's
  public DNS, never a way in from the internet. The certificate comes from
  `longx-cert` (`Longx.Tls.Tool`, lego inside, 222 DNS providers), run by
  `Longx.Tls.Manager`, renewed by `Longx.Tls.RenewWorker`, served by
  `Longx.Tls.Listener` beside the plain http port.

  What the settings page saves (`Longx.System.Setting`, encrypted at rest):
  `tls` — the names, the provider, the CA, the port, whether plain http
  pages are redirected; `tls_env` — the provider's variables by lego's
  names (credentials and options), accepted only when the provider declares
  them (the tool runs with them in its environment) and never read back,
  only named; `tls_account` — the ACME account the tool returned, handed
  back for every renewal. The certificate lives in files under `dir/0`
  (`config :longx, Longx.Tls, dir:` — dev `data/tls`, prod
  `$LONGX_DATA_DIR/tls`), the key readable by its owner alone.
  """

  alias Longx.System, as: Sys

  @settings_key "tls"
  @env_key "tls_env"
  @account_key "tls_account"

  @defaults %{
    enabled: false,
    domains: [],
    provider: nil,
    email: "",
    directory: "letsencrypt",
    port: 7443,
    redirect: true
  }

  @domain ~r/^(\*\.)?([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/
  @email ~r/^[^@\s]+@[^@\s]+\.[^@\s]+$/

  @type settings :: %{
          enabled: boolean,
          domains: [String.t()],
          provider: String.t() | nil,
          email: String.t(),
          directory: String.t(),
          port: pos_integer,
          redirect: boolean
        }

  ## Settings

  @doc "What is saved, over the defaults."
  @spec settings() :: settings
  def settings do
    stored = read_json(@settings_key) || %{}

    Map.new(@defaults, fn {key, default} ->
      {key, Map.get(stored, Atom.to_string(key), default)}
    end)
  end

  @doc """
  Saves the given fields over what is there. `env:` maps the provider's
  variable names to values: an empty string keeps the stored value, nil
  removes it; another provider drops the previous one's variables. Answers
  the settings, or `{:error, field, message}`.
  """
  @spec save(map) :: {:ok, settings} | {:error, atom, String.t()}
  def save(attrs) when is_map(attrs) do
    current = settings()
    merged = Map.merge(current, Map.take(attrs, Map.keys(@defaults)))

    with {:ok, settings} <- validate(merged),
         {:ok, env} <- merge_env(settings, current, Map.get(attrs, :env) || %{}) do
      :ok = write_json(@settings_key, Map.new(settings, fn {k, v} -> {Atom.to_string(k), v} end))
      :ok = write_json(@env_key, env)
      {:ok, settings}
    end
  end

  defp validate(s) do
    with {:ok, domains} <- domains(s.domains),
         {:ok, provider} <- canonical_provider(s.provider),
         :ok <- enabled_needs(s.enabled, domains, provider),
         :ok <- port(s.port),
         :ok <- directory(s.directory),
         :ok <- email(s.email),
         :ok <- boolean(:redirect, s.redirect),
         :ok <- boolean(:enabled, s.enabled) do
      {:ok, %{s | domains: domains, provider: provider}}
    end
  end

  defp domains(list) when is_list(list) do
    list
    |> Enum.map(&(&1 |> to_string() |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, []}, fn domain, {:ok, acc} ->
      if Regex.match?(@domain, domain),
        do: {:cont, {:ok, [domain | acc]}},
        else: {:halt, {:error, :domains, "#{inspect(domain)} is not a DNS name"}}
    end)
    |> case do
      {:ok, acc} -> {:ok, acc |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp domains(_), do: {:error, :domains, "a list of names"}

  defp canonical_provider(nil), do: {:ok, nil}
  defp canonical_provider(""), do: {:ok, nil}

  defp canonical_provider(name) when is_binary(name) do
    case provider(String.trim(name)) do
      %{code: code} -> {:ok, code}
      nil -> {:error, :provider, "#{inspect(name)} is not a DNS provider longx-cert knows"}
    end
  end

  defp canonical_provider(_), do: {:error, :provider, "a provider code"}

  defp enabled_needs(true, [], _),
    do: {:error, :domains, "at least one name is needed to turn HTTPS on"}

  defp enabled_needs(true, _, nil),
    do: {:error, :provider, "a DNS provider is needed to turn HTTPS on"}

  defp enabled_needs(_, _, _), do: :ok

  defp port(port) when is_integer(port) and port in 1..65_535 do
    if port == http_port(),
      do: {:error, :port, "#{port} is the plain http port"},
      else: :ok
  end

  defp port(_), do: {:error, :port, "a port between 1 and 65535"}

  defp directory(dir) when dir in ["letsencrypt", "letsencrypt-staging"], do: :ok
  defp directory("https://" <> rest) when rest != "", do: :ok

  defp directory(dir),
    do:
      {:error, :directory,
       "#{inspect(dir)}: letsencrypt, letsencrypt-staging or an https ACME directory"}

  defp email(""), do: :ok

  defp email(email) when is_binary(email) do
    if Regex.match?(@email, email),
      do: :ok,
      else: {:error, :email, "#{inspect(email)} is not an address"}
  end

  defp email(_), do: {:error, :email, "an address"}

  defp boolean(_field, value) when is_boolean(value), do: :ok
  defp boolean(field, _), do: {:error, field, "true or false"}

  defp merge_env(settings, current, updates) when is_map(updates) do
    base = if settings.provider == current.provider, do: env(), else: %{}
    allowed = variable_names(settings.provider)

    case updates
         |> Map.keys()
         |> Enum.map(&to_string/1)
         |> Enum.reject(&(&1 in allowed))
         |> Enum.sort() do
      [] ->
        apply_env(Map.take(base, allowed), updates)

      refused ->
        {:error, :env,
         "#{Enum.join(refused, ", ")}: not variables of #{settings.provider || "a DNS provider (none chosen)"}"}
    end
  end

  defp merge_env(_settings, _current, _), do: {:error, :env, "a map of variable names to values"}

  defp apply_env(base, updates) do
    Enum.reduce_while(updates, {:ok, base}, fn {name, value}, {:ok, acc} ->
      name = to_string(name)

      cond do
        is_nil(value) ->
          {:cont, {:ok, Map.delete(acc, name)}}

        value == "" ->
          {:cont, {:ok, acc}}

        is_binary(value) ->
          {:cont, {:ok, Map.put(acc, name, value)}}

        true ->
          {:halt, {:error, :env, "#{name}: a string"}}
      end
    end)
  end

  defp variable_names(nil), do: []

  defp variable_names(code) do
    case provider(code) do
      %{credentials: credentials, additional: additional} ->
        Enum.map(credentials ++ additional, & &1.name)

      nil ->
        []
    end
  end

  @doc "The provider's variables as stored (for the tool, never for the page)."
  @spec env() :: %{String.t() => String.t()}
  def env, do: read_json(@env_key) || %{}

  @doc "The names of the variables that have a value: what the page may know."
  @spec env_names() :: [String.t()]
  def env_names, do: env() |> Map.keys() |> Enum.sort()

  ## Providers

  @doc "lego's DNS providers as the pinned `longx-cert providers` lists them (`priv/tls/providers.json`)."
  @spec providers() :: [map]
  def providers do
    case :persistent_term.get({__MODULE__, :providers}, nil) do
      nil ->
        providers =
          Application.app_dir(:longx, ["priv", "tls", "providers.json"])
          |> File.read!()
          |> Jason.decode!()
          |> Enum.map(fn p ->
            %{
              code: p["code"],
              name: p["name"],
              url: p["url"],
              aliases: p["aliases"] || [],
              credentials: variables(p["credentials"]),
              additional: variables(p["additional"])
            }
          end)

        :persistent_term.put({__MODULE__, :providers}, providers)
        providers

      providers ->
        providers
    end
  end

  defp variables(list),
    do: Enum.map(list || [], &%{name: &1["name"], description: &1["description"]})

  @doc "A provider by code or alias."
  @spec provider(String.t()) :: map | nil
  def provider(name), do: Enum.find(providers(), &(&1.code == name or name in &1.aliases))

  ## The tool's request and what it answers

  @doc "What `longx-cert obtain` is handed: the settings, the variables, the account."
  @spec request() :: map
  def request do
    s = settings()

    %{
      "directory" => s.directory,
      "domains" => s.domains,
      "provider" => s.provider,
      "email" => s.email,
      "env" => env(),
      "account" => read_json(@account_key),
      "key_type" => "EC256"
    }
  end

  @doc "Keeps the ACME account the tool returned, for the next renewal."
  @spec store_account(map) :: :ok
  def store_account(account) when is_map(account), do: write_json(@account_key, account)

  @doc "Where the certificate lives (`config :longx, Longx.Tls, dir:`)."
  @spec dir() :: Path.t()
  def dir,
    do: Keyword.get(Application.get_env(:longx, Longx.Tls, []), :dir) || Path.expand("data/tls")

  @spec cert_path() :: Path.t()
  def cert_path, do: Path.join(dir(), "cert.pem")

  @spec key_path() :: Path.t()
  def key_path, do: Path.join(dir(), "key.pem")

  @doc """
  Writes a certificate the tool answered: the chain, the key (owner only),
  what the page shows about it; each file replaced whole. The account it
  came with is kept for the renewal.
  """
  @spec store_certificate(map) :: :ok
  def store_certificate(%{"certificate" => cert, "private_key" => key} = result) do
    File.mkdir_p!(dir())
    write_atomic(key_path(), key, 0o600)
    write_atomic(cert_path(), cert, 0o644)

    meta = %{
      "domains" => result["domains"] || [],
      "not_before" => result["not_before"],
      "not_after" => result["not_after"],
      "serial" => result["serial"],
      "issued_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    write_atomic(Path.join(dir(), "meta.json"), Jason.encode!(meta), 0o644)
    if account = result["account"], do: store_account(account)
    :ok
  end

  @doc "The certificate in the files, as the page shows it; nil when there is none."
  @spec certificate() :: map | nil
  def certificate do
    with true <- File.regular?(cert_path()) and File.regular?(key_path()),
         {:ok, json} <- File.read(Path.join(dir(), "meta.json")),
         {:ok, meta} <- Jason.decode(json) do
      %{
        domains: meta["domains"] || [],
        not_before: datetime(meta["not_before"]),
        not_after: datetime(meta["not_after"]),
        serial: meta["serial"],
        issued_at: datetime(meta["issued_at"])
      }
    else
      _ -> nil
    end
  end

  defp datetime(nil), do: nil

  defp datetime(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp write_atomic(path, content, mode) do
    tmp = path <> ".tmp-#{System.unique_integer([:positive])}"
    File.write!(tmp, "")
    File.chmod!(tmp, mode)
    File.write!(tmp, content)
    File.rename!(tmp, path)
  end

  ## What the settings page shows

  @doc """
  The page's view: the settings, the names of the provider's variables that
  have a value (never the values), the issuance's stage, the certificate on
  disk, whether and where HTTPS is served, this machine's addresses and
  what each name resolves to now (the A record the person adds), the tool.
  """
  @spec report() :: map
  def report do
    s = settings()
    status = Longx.Tls.Manager.status()
    addresses = local_addresses()

    %{
      enabled: s.enabled,
      domains: s.domains,
      provider: s.provider,
      email: s.email,
      directory: s.directory,
      port: s.port,
      redirect: s.redirect,
      http_port: http_port(),
      env_set: env_names(),
      stage: Atom.to_string(status.stage),
      received: status.received,
      total: status.total,
      error: status.error,
      started_at: status.started_at,
      finished_at: status.finished_at,
      certificate: certificate(),
      serving: Longx.Tls.Listener.running?(),
      url: https_url(),
      addresses: addresses,
      resolution: resolution(s.domains, addresses),
      tool_version: Longx.Tls.Tool.version(),
      tool_installed: match?({:ok, _, _}, Longx.Tls.Tool.resolve())
    }
  end

  @doc "This machine's IPv4 addresses a LAN reaches it by (`pick_addresses/1` over `:inet.getifaddrs/0`)."
  @spec local_addresses() :: [String.t()]
  def local_addresses do
    case :inet.getifaddrs() do
      {:ok, interfaces} -> pick_addresses(interfaces)
      _ -> []
    end
  end

  @virtual ~r/^(docker|br-|veth|virbr|cni|flannel|lxc|vmnet|vboxnet)/

  @doc """
  The IPv4 addresses of the interfaces that are up, loopback (WSL puts one of
  its own there), link-local and virtual bridges (containers, VMs) left out;
  192.168/16 first, then 10/8, then 172.16/12, then the rest (a VPN's).
  """
  @spec pick_addresses([{charlist, keyword}]) :: [String.t()]
  def pick_addresses(interfaces) do
    for {name, opts} <- interfaces,
        flags = Keyword.get(opts, :flags, []),
        :up in flags and :loopback not in flags,
        not Regex.match?(@virtual, to_string(name)),
        {:addr, {a, b, _, _} = ip} <- opts,
        a != 127 and not (a == 169 and b == 254),
        uniq: true do
      ip
    end
    |> Enum.with_index()
    |> Enum.sort_by(fn {ip, index} -> {rank(ip), index} end)
    |> Enum.map(fn {ip, _} -> ip |> :inet.ntoa() |> to_string() end)
  end

  defp rank({192, 168, _, _}), do: 0
  defp rank({10, _, _, _}), do: 1
  defp rank({172, b, _, _}) when b in 16..31, do: 2
  defp rank(_), do: 3

  # each name looked up now (two seconds at most), wildcards left out
  defp resolution(domains, addresses) do
    domains
    |> Enum.reject(&String.starts_with?(&1, "*."))
    |> Enum.map(fn domain ->
      Task.async(fn ->
        case :inet.getaddrs(String.to_charlist(domain), :inet) do
          {:ok, ips} -> Enum.map(ips, &(&1 |> :inet.ntoa() |> to_string()))
          _ -> []
        end
      end)
      |> then(&{domain, &1})
    end)
    |> Enum.map(fn {domain, task} ->
      found =
        case Task.yield(task, 2_000) || Task.shutdown(task, :brutal_kill) do
          {:ok, ips} -> ips
          _ -> []
        end

      %{domain: domain, addresses: found, here: Enum.any?(found, &(&1 in addresses))}
    end)
  end

  ## The address HTTPS is served at

  @doc """
  Where HTTPS is served now (`https://lx.example.com:7443`), nil while it is
  not — published by `Longx.Tls.Manager` whenever the listener starts or stops.
  """
  @spec https_url() :: String.t() | nil
  def https_url, do: :persistent_term.get({__MODULE__, :served}, %{url: nil}).url

  @doc "Where a plain http page is sent (`https_url/0` when the settings say to redirect), else nil."
  @spec redirect_url() :: String.t() | nil
  def redirect_url do
    case :persistent_term.get({__MODULE__, :served}, %{url: nil, redirect: false}) do
      %{url: url, redirect: true} -> url
      _ -> nil
    end
  end

  @doc false
  @spec publish(String.t() | nil, boolean) :: :ok
  def publish(url, redirect) do
    :persistent_term.put({__MODULE__, :served}, %{url: url, redirect: redirect and url != nil})
    :ok
  end

  @doc "The plain http port the endpoint serves."
  @spec http_port() :: pos_integer | nil
  def http_port, do: get_in(LongxWeb.Endpoint.config(:http) || [], [:port])

  ## the settings store

  defp read_json(key) do
    case Sys.get_setting(key) do
      {:ok, %{value: value}} when is_binary(value) and value != "" ->
        case Jason.decode(value) do
          {:ok, decoded} -> decoded
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp write_json(key, value) do
    {:ok, _} = Sys.put_setting(key, Jason.encode!(value))
    :ok
  end
end
