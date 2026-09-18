defmodule Longx.Credentials.Http do
  @moduledoc """
  The one way a credential is used: a request the service layer makes on
  the agent's behalf. The value goes into the header the row names (or
  wherever a `{{credential:NAME}}` placeholder stands in the URL, the
  headers or the body); the URL's host must be in the row's
  `allowed_hosts` and redirects are not followed (a redirect could carry
  the header elsewhere); an OAuth2 access token about to expire is
  refreshed first; and the answer — status, headers, body — comes back
  with every secret value replaced by `[redacted:NAME]`, so what the model
  reads never contains one.
  """

  alias Longx.Credentials
  alias Longx.Credentials.{Credential, OAuth}

  @type response :: %{status: pos_integer, headers: %{String.t() => String.t()}, body: binary}

  # a token this close to its expiry is refreshed before use
  @refresh_margin_s 60
  @placeholder ~r/\{\{\s*credential:([a-z0-9_-]+)\s*\}\}/

  @doc """
  `request(name, method, url, headers: %{} | [], body: binary | nil,
  timeout_ms: 60_000)`. Errors: `:not_found`, `:needs_login` (no value
  yet), `:expired` (past its time with nothing to refresh it),
  `{:refresh_failed, message}`, `{:host_not_allowed, host}`,
  `{:bad_url, url}`, `{:transport, message}`.
  """
  @spec request(String.t(), String.t() | atom, String.t(), keyword) ::
          {:ok, response} | {:error, term}
  def request(name, method, url, opts \\ []) when is_binary(name) and is_binary(url) do
    with {:ok, cred} <- Credentials.reveal(name),
         {:ok, value} <- value_for(cred),
         url = substitute(url, name, value),
         {:ok, uri} <- parse_url(url),
         :ok <- host_allowed(uri, cred),
         {:ok, method} <- method_of(method) do
      headers =
        opts
        |> Keyword.get(:headers, %{})
        |> normalise_headers()
        |> Enum.map(fn {k, v} -> {k, substitute(v, name, value)} end)
        |> inject(cred, value)

      body =
        case Keyword.get(opts, :body) do
          nil -> nil
          text when is_binary(text) -> substitute(text, name, value)
        end

      # the value in use may be fresher than the row read above (a refresh)
      secrets = Enum.uniq([value | secret_values(cred)])

      case Req.request(
             method: method,
             url: URI.to_string(uri),
             headers: headers,
             body: body,
             retry: false,
             redirect: false,
             decode_body: false,
             receive_timeout: Keyword.get(opts, :timeout_ms, 60_000)
           ) do
        {:ok, %Req.Response{status: status, headers: resp_headers, body: resp_body}} ->
          {:ok,
           %{
             status: status,
             headers: scrub_headers(resp_headers, secrets, name),
             body: scrub(to_binary(resp_body), secrets, name)
           }}

        {:error, reason} ->
          {:error, {:transport, scrub(Exception.message(reason), secrets, name)}}
      end
    end
  end

  @doc "Every secret value of a revealed row (for scrubbing)."
  @spec secret_values(Credential.t()) :: [String.t()]
  def secret_values(%Credential{} = cred) do
    [cred.secret, cred.access_token, cred.refresh_token, cred.client_secret]
    |> Enum.filter(&(is_binary(&1) and byte_size(&1) >= 4))
  end

  @doc "Replaces every secret value in `text` by `[redacted:NAME]`."
  @spec scrub(binary, [String.t()], String.t()) :: binary
  def scrub(text, secrets, name) when is_binary(text) do
    Enum.reduce(secrets, text, fn secret, acc ->
      String.replace(acc, secret, "[redacted:" <> name <> "]")
    end)
  end

  ## pieces

  # the value to send: the key, or a fresh enough access token
  defp value_for(%Credential{kind: :api_key, secret: secret}) when is_binary(secret),
    do: {:ok, secret}

  defp value_for(%Credential{kind: :api_key}), do: {:error, :needs_login}

  defp value_for(%Credential{kind: :oauth2, access_token: nil}), do: {:error, :needs_login}

  defp value_for(%Credential{kind: :oauth2} = cred) do
    cond do
      not stale?(cred.expires_at) ->
        {:ok, cred.access_token}

      is_binary(cred.refresh_token) ->
        case OAuth.refresh(cred) do
          {:ok, fresh} ->
            {:ok, fresh} = Credentials.reveal(fresh)
            {:ok, fresh.access_token}

          {:error, message} ->
            {:error, {:refresh_failed, message}}
        end

      true ->
        {:error, :expired}
    end
  end

  defp stale?(nil), do: false

  defp stale?(%DateTime{} = at),
    do: DateTime.diff(at, DateTime.utc_now(), :second) < @refresh_margin_s

  defp substitute(text, name, value) when is_binary(text) do
    Regex.replace(@placeholder, text, fn whole, found ->
      if found == name, do: value, else: whole
    end)
  end

  defp parse_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, uri}

      _ ->
        {:error, {:bad_url, url}}
    end
  end

  defp host_allowed(%URI{host: host}, %Credential{allowed_hosts: hosts}) do
    if String.downcase(host) in hosts, do: :ok, else: {:error, {:host_not_allowed, host}}
  end

  defp method_of(method) when is_atom(method), do: {:ok, method}

  defp method_of(method) when is_binary(method) do
    case String.downcase(method) do
      m when m in ~w(get post put patch delete head options) -> {:ok, String.to_atom(m)}
      other -> {:error, {:bad_method, other}}
    end
  end

  defp normalise_headers(headers) when is_map(headers),
    do: headers |> Map.to_list() |> normalise_headers()

  defp normalise_headers(headers) when is_list(headers),
    do: Enum.map(headers, fn {k, v} -> {k |> to_string() |> String.downcase(), to_string(v)} end)

  # the credential's own header, unless the caller set it (a placeholder there)
  defp inject(headers, %Credential{header: header, scheme: scheme}, value) do
    name = String.downcase(header)

    if List.keymember?(headers, name, 0),
      do: headers,
      else: headers ++ [{name, if(scheme in [nil, ""], do: value, else: scheme <> " " <> value)}]
  end

  defp scrub_headers(headers, secrets, name) do
    Map.new(headers, fn {k, v} ->
      {to_string(k),
       v |> List.wrap() |> Enum.map_join(", ", &scrub(to_string(&1), secrets, name))}
    end)
  end

  defp to_binary(body) when is_binary(body), do: body
  defp to_binary(body), do: inspect(body)
end
