defmodule Longx.Credentials.OAuth do
  @moduledoc """
  The OAuth2 side of a credential: a login (authorization code with PKCE
  S256 and a state, the browser sent back to `<public url>/callback/
  credentials` — one stable redirect URI per Longx instance, the one to
  register at the provider), the code exchange, the refresh_token grant,
  and RFC 7591 dynamic client registration for servers that offer it (an
  MCP server, typically). Every token request is a form POST to
  `token_url` with the row's `extra_params` added; the answer's
  `expires_in` becomes `expires_at`; a refresh token in the answer replaces
  the old one, none keeps it. Nothing here reaches the model: the tokens
  land on the row (`Longx.Credentials.store_tokens/2`) and are used by
  `Longx.Credentials.Http`.
  """

  alias Longx.Credentials
  alias Longx.Credentials.{Credential, Logins}

  @callback_path "/callback/credentials"

  @doc """
  The redirect URI logins use. A provider takes an https address or a
  loopback one (RFC 8252 — COROS answers `invalid_redirect_uri: Remote
  redirect_uri must use https` to anything else), never a remote plain-http
  address like a LAN box: the browser's origin (else the public URL) is
  used when it is https, otherwise Longx's own `http://127.0.0.1:<port>`.
  A browser on the Longx machine then lands on Longx directly; one elsewhere
  lands on an unreachable page and the person pastes its address back
  (`complete_url/1`).
  """
  @spec redirect_uri(String.t() | nil) :: String.t()
  def redirect_uri(origin) do
    base =
      case origin && URI.parse(String.trim(origin)) do
        %URI{scheme: scheme, host: host} = uri
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          URI.to_string(%URI{uri | path: nil, query: nil, fragment: nil})

        _ ->
          Longx.System.public_url()
      end

    case URI.parse(base) do
      %URI{scheme: "https"} -> String.trim_trailing(base, "/") <> @callback_path
      _ -> "http://127.0.0.1:#{own_port()}" <> @callback_path
    end
  end

  @doc "Whether a redirect URI is the loopback one (the person may have to paste the address back)."
  @spec loopback?(String.t()) :: boolean
  def loopback?(uri), do: match?(%URI{host: "127.0.0.1"}, URI.parse(uri))

  defp own_port do
    case LongxWeb.Endpoint.config(:http) do
      http when is_list(http) -> Keyword.get(http, :port) || 7788
      _ -> 7788
    end
  end

  @doc """
  The address the browser was sent to, pasted back by the person: its
  `state` and `code` / `error` complete the login like the callback does.
  """
  @spec complete_url(String.t()) :: {:ok, Credential.t()} | {:error, String.t()}
  def complete_url(url) when is_binary(url) do
    params =
      case URI.parse(String.trim(url)) do
        %URI{query: query} when is_binary(query) -> URI.decode_query(query)
        _ -> %{}
      end

    case Map.pop(params, "state") do
      {state, rest} when is_binary(state) and state != "" ->
        case complete(state, rest) do
          {:error, :unknown_state} ->
            {:error,
             "no login is waiting for this address (its state is unknown or already used)"}

          other ->
            other
        end

      _ ->
        {:error,
         "not a redirect address: no state in it — paste the whole address the browser was sent to"}
    end
  end

  @doc """
  Starts a login: registers the client first when the row has none and a
  `registration_url`, remembers the state, and answers the URL to send
  the browser to. Options: `origin:` (the redirect base), `notify:` (a pid
  told `{:credential_login, state, {:ok, cred} | {:error, why}}`).
  """
  @spec begin_login(Credential.t(), keyword) ::
          {:ok, %{url: String.t(), state: String.t(), redirect_uri: String.t()}}
          | {:error, String.t()}
  def begin_login(%Credential{} = cred, opts) do
    # a redirect the provider dictates wins over Longx's own
    redirect = fixed_redirect(cred) || redirect_uri(Keyword.get(opts, :origin))

    with :ok <- oauth2?(cred),
         :ok <- present(cred.authorize_url, "no authorize URL"),
         {:ok, cred} <- ensure_client(cred, redirect),
         {:ok, cred} <- accepted_client(cred, redirect) do
      state = random(24)
      verifier = if cred.pkce, do: random(32)

      :ok =
        Logins.put(state, %{
          credential_id: cred.id,
          verifier: verifier,
          redirect_uri: redirect,
          notify: Keyword.get(opts, :notify),
          # an agent's tool waiting on an ask that carries this state (Plugs.Credentials)
          thread_id: Keyword.get(opts, :thread_id)
        })

      query =
        cred.authorize_params
        |> Map.merge(%{
          "response_type" => "code",
          "client_id" => cred.client_id,
          "redirect_uri" => redirect,
          "state" => state
        })
        |> put_if("scope", cred.scopes)
        |> put_if("code_challenge", verifier && challenge(verifier))
        |> put_if("code_challenge_method", verifier && "S256")

      {:ok, %{url: with_query(cred.authorize_url, query), state: state, redirect_uri: redirect}}
    end
  end

  @doc """
  The browser came back: the query's `code` is exchanged with the
  remembered verifier and the tokens stored; an `error` from the provider,
  an unknown state or a refused exchange ends the login with the reason.
  """
  @spec complete(String.t(), map) :: {:ok, Credential.t()} | {:error, :unknown_state | String.t()}
  def complete(state, params) when is_binary(state) and is_map(params) do
    with {:ok, login} <- take(state),
         {:ok, cred} <- fetch_by_id(login.credential_id) do
      result =
        case params do
          %{"error" => error} ->
            {:error, "the provider refused the login: #{error} #{params["error_description"]}"}

          %{"code" => code} when is_binary(code) and code != "" ->
            exchange(cred, code, login.verifier, login.redirect_uri)

          _ ->
            {:error, "the provider sent no code back"}
        end

      if is_pid(login.notify), do: send(login.notify, {:credential_login, state, result})
      if is_binary(login[:thread_id]), do: answer_ask(login.thread_id, state, result)
      result
    end
  end

  # the tool waiting on the thread's ask that carries this state is answered
  # here, so the person need not press anything after the browser came back
  defp answer_ask(thread_id, state, result) do
    answer =
      case result do
        {:ok, _} -> %{"login" => "ok"}
        {:error, message} -> %{"login" => "error", "message" => to_string(message)}
      end

    thread_id
    |> Longx.Agent.ThreadState.Store.requests()
    |> Enum.find(&(get_in(&1.params, ["meta", "login"]) == state))
    |> case do
      %{id: id} -> Longx.Agent.respond(thread_id, id, answer)
      nil -> :ok
    end
  end

  defp take(state) do
    case Logins.take(state) do
      {:ok, login} -> {:ok, login}
      :error -> {:error, :unknown_state}
    end
  end

  @doc "Exchanges an authorization code for tokens and stores them."
  @spec exchange(Credential.t(), String.t(), String.t() | nil, String.t()) ::
          {:ok, Credential.t()} | {:error, String.t()}
  def exchange(%Credential{} = cred, code, verifier, redirect) do
    {:ok, cred} = Credentials.reveal(cred)

    form =
      %{"grant_type" => "authorization_code", "code" => code, "redirect_uri" => redirect}
      |> put_if("code_verifier", verifier)

    with {:ok, tokens} <- token_request(cred, form) do
      Credentials.store_tokens(cred, tokens)
    end
  end

  @doc "The refresh_token grant; the outcome lands on the row either way."
  @spec refresh(Credential.t()) :: {:ok, Credential.t()} | {:error, :needs_login | String.t()}
  def refresh(%Credential{} = cred) do
    with :ok <- oauth2?(cred),
         {:ok, cred} <- Credentials.reveal(cred),
         :ok <- present(cred.refresh_token, :needs_login),
         :ok <- present(cred.token_url, "no token URL") do
      case token_request(cred, %{
             "grant_type" => "refresh_token",
             "refresh_token" => cred.refresh_token
           }) do
        {:ok, tokens} ->
          # a refresh answer without a refresh token keeps the one we have
          Credentials.store_tokens(cred, Map.put_new(tokens, :refresh_token, cred.refresh_token))

        {:error, message} ->
          {:ok, _} = Credentials.record_error(cred, message)
          {:error, message}
      end
    end
  end

  @doc "RFC 7591: registers Longx as a public client at `registration_url`, stores the client id."
  @spec register(Credential.t(), String.t()) :: {:ok, Credential.t()} | {:error, String.t()}
  def register(%Credential{registration_url: url} = cred, redirect) when is_binary(url) do
    body = %{
      "client_name" => "Longx",
      "redirect_uris" => [redirect],
      "grant_types" => ["authorization_code", "refresh_token"],
      "response_types" => ["code"],
      "token_endpoint_auth_method" => "none"
    }

    case Req.post(url, json: body, retry: false, receive_timeout: 30_000) do
      {:ok, %{status: status, body: %{"client_id" => id} = answer}} when status in 200..299 ->
        Credentials.store_client(cred, %{client_id: id, client_secret: answer["client_secret"]})

      {:ok, %{status: status, body: body}} ->
        {:error, "registration at #{url} answered #{status}: #{describe(body)}"}

      {:error, reason} ->
        {:error, "registration at #{url} failed: #{Exception.message(reason)}"}
    end
  end

  def register(_cred, _redirect), do: {:error, "no client id and no registration URL"}

  ## pieces

  defp ensure_client(%Credential{client_id: id} = cred, _redirect)
       when is_binary(id) and id != "",
       do: {:ok, cred}

  defp ensure_client(%Credential{registration_url: url} = cred, redirect)
       when is_binary(url) and url != "",
       do: register(cred, redirect)

  defp ensure_client(_cred, _redirect),
    do: {:error, "no client id: enter one, or a registration URL the server offers"}

  # A client Longx cannot vouch for is replaced by one it registers itself
  # when the server registers clients (the row's registration URL, else the
  # `registration_endpoint` of the server's RFC 8414 metadata): a *public*
  # client (no secret) whose row carries no registration URL was registered
  # by someone else — an agent once registered one by hand with a loopback
  # redirect URI and handed over the id; COROS only rejects that after the
  # IdP login, with the ticket, so no probe can see it — and a client the
  # authorize endpoint refuses outright (a probe answering 400). A
  # confidential client (a secret from the provider's console) is used as it
  # is; no way to register: the login goes on as it is.
  defp accepted_client(%Credential{fixed_client: true} = cred, _redirect), do: {:ok, cred}

  defp accepted_client(%Credential{} = cred, redirect) do
    cond do
      foreign_public_client?(cred) or probe_authorize(cred, redirect) == :rejected ->
        case registration_url(cred) do
          nil ->
            {:ok, cred}

          url ->
            # a refused registration is the login's error: the provider's words
            # (a remote http redirect URI, a scope) are what the person needs
            with {:ok, cred} <- Credentials.update_credential(cred, %{registration_url: url}) do
              register(cred, redirect)
            end
        end

      true ->
        {:ok, cred}
    end
  end

  defp foreign_public_client?(%Credential{client_id: id, registration_url: reg} = cred) do
    is_binary(id) and id != "" and (is_nil(reg) or reg == "") and
      not confidential?(cred)
  end

  defp confidential?(%Credential{} = cred) do
    case Credentials.reveal(cred) do
      {:ok, %{client_secret: secret}} -> is_binary(secret) and secret != ""
      _ -> false
    end
  end

  defp probe_authorize(%Credential{} = cred, redirect) do
    query = %{
      "response_type" => "code",
      "client_id" => cred.client_id,
      "redirect_uri" => redirect,
      "state" => "probe"
    }

    case Req.get(with_query(cred.authorize_url, query),
           redirect: false,
           retry: false,
           receive_timeout: 10_000
         ) do
      {:ok, %{status: 400}} -> :rejected
      _ -> :ok
    end
  end

  defp registration_url(%Credential{registration_url: url}) when is_binary(url) and url != "",
    do: url

  defp registration_url(%Credential{authorize_url: authorize}) do
    # the origin as a string (a %URI{} built by hand trips dialyzer's opaque check)
    %URI{scheme: scheme, host: host, port: port} = URI.parse(authorize)
    default_port = URI.default_port(scheme || "https")
    origin = "#{scheme}://#{host}#{if port && port != default_port, do: ":#{port}", else: ""}"

    Enum.find_value(
      ["/.well-known/oauth-authorization-server", "/.well-known/openid-configuration"],
      fn path ->
        case Req.get(origin <> path, retry: false, receive_timeout: 10_000) do
          {:ok, %{status: 200, body: %{"registration_endpoint" => url}}} when is_binary(url) ->
            url

          _ ->
            nil
        end
      end
    )
  end

  defp fixed_redirect(%Credential{redirect_uri: uri}) when is_binary(uri) and uri != "", do: uri
  defp fixed_redirect(_cred), do: nil

  ## The device-code flow (OpenAI's Codex one)

  @doc """
  Starts a device-code login (`device_flow: :openai`): the vendor hands a
  user code the person types at `verification_url`; `device_poll/1` with
  the returned `state` asks whether they did and finishes the login. No
  redirect, no port, no address to paste: the way for a Longx on a server
  the browser is not on.
  """
  @spec device_begin(Credential.t(), keyword) ::
          {:ok,
           %{
             state: String.t(),
             user_code: String.t(),
             verification_url: String.t(),
             interval: pos_integer
           }}
          | {:error, String.t()}
  def device_begin(%Credential{} = cred, opts \\ []) do
    with :ok <- oauth2?(cred),
         :ok <- device_flow?(cred),
         :ok <- present(cred.client_id, "no client id"),
         {:ok, issuer} <- issuer(cred) do
      case Req.post(issuer <> "/api/accounts/deviceauth/usercode",
             json: %{"client_id" => cred.client_id},
             retry: false,
             receive_timeout: 30_000
           ) do
        {:ok, %{status: 200, body: %{"device_auth_id" => id, "user_code" => code} = body}}
        when is_binary(id) and is_binary(code) ->
          state = random(24)
          interval = interval_of(body["interval"])

          :ok =
            Logins.put(state, %{
              credential_id: cred.id,
              device_auth_id: id,
              user_code: code,
              issuer: issuer,
              notify: Keyword.get(opts, :notify),
              thread_id: Keyword.get(opts, :thread_id)
            })

          {:ok,
           %{
             state: state,
             user_code: code,
             verification_url: issuer <> "/codex/device",
             interval: interval
           }}

        {:ok, %{status: 404}} ->
          {:error, "the provider offers no device-code login; use the browser login"}

        {:ok, %{status: status, body: body}} ->
          {:error, "the device-code request answered #{status}: #{describe(body)}"}

        {:error, reason} ->
          {:error, "the device-code request failed: #{Exception.message(reason)}"}
      end
    end
  end

  @doc """
  One poll of a device-code login: `{:ok, :pending}` while the person has
  not typed the code, the credential once they did (the vendor hands the
  authorization code and the PKCE verifier it made; the exchange uses the
  vendor's own callback), an error when the login is refused or unknown.
  """
  @spec device_poll(String.t()) ::
          {:ok, :pending} | {:ok, Credential.t()} | {:error, :unknown_state | String.t()}
  def device_poll(state) when is_binary(state) do
    case Logins.get(state) do
      {:ok, %{device_auth_id: id, user_code: code, issuer: issuer} = login} ->
        case Req.post(issuer <> "/api/accounts/deviceauth/token",
               json: %{"device_auth_id" => id, "user_code" => code},
               retry: false,
               receive_timeout: 30_000
             ) do
          {:ok, %{status: 200, body: %{"authorization_code" => auth_code} = body}}
          when is_binary(auth_code) ->
            {:ok, _} = Logins.take(state)

            result =
              with {:ok, cred} <- fetch_by_id(login.credential_id) do
                exchange(cred, auth_code, body["code_verifier"], issuer <> "/deviceauth/callback")
              end

            if is_pid(login[:notify]),
              do: send(login[:notify], {:credential_login, state, result})

            if is_binary(login[:thread_id]), do: answer_ask(login[:thread_id], state, result)
            result

          {:ok, %{status: status}} when status in [403, 404] ->
            {:ok, :pending}

          {:ok, %{status: status, body: body}} ->
            {:ok, _} = Logins.take(state)
            {:error, "the device-code login answered #{status}: #{describe(body)}"}

          {:error, reason} ->
            {:error, "the device-code poll failed: #{Exception.message(reason)}"}
        end

      _ ->
        {:error, :unknown_state}
    end
  end

  defp device_flow?(%Credential{device_flow: :openai}), do: :ok
  defp device_flow?(_cred), do: {:error, "this credential has no device-code login"}

  # the vendor's origin, off the authorize URL
  defp issuer(%Credential{authorize_url: url}) when is_binary(url) and url != "" do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port} when is_binary(host) ->
        default_port = URI.default_port(scheme || "https")
        {:ok, "#{scheme}://#{host}#{if port && port != default_port, do: ":#{port}", else: ""}"}

      _ ->
        {:error, "no authorize URL"}
    end
  end

  defp issuer(_cred), do: {:error, "no authorize URL"}

  defp interval_of(n) when is_integer(n) and n > 0, do: n

  defp interval_of(n) when is_binary(n),
    do:
      case(Integer.parse(n),
        do: (
          {v, _} when v > 0 -> v
          _ -> 5
        )
      )

  defp interval_of(_), do: 5

  defp oauth2?(%Credential{kind: :oauth2}), do: :ok
  defp oauth2?(_), do: {:error, "not an OAuth2 credential"}

  defp present(value, _error) when is_binary(value) and value != "", do: :ok
  defp present(_value, error), do: {:error, error}

  # a form POST to the token endpoint; the row's client and extra params ride along
  defp token_request(%Credential{} = cred, form) do
    with :ok <- present(cred.token_url, "no token URL") do
      form =
        cred.extra_params
        |> Map.merge(form)
        |> put_if("client_id", cred.client_id)
        |> put_if("client_secret", cred.client_secret)

      case Req.post(cred.token_url,
             form: form,
             headers: [{"accept", "application/json"}],
             retry: false,
             receive_timeout: 30_000
           ) do
        {:ok, %{status: 200, body: %{"access_token" => token} = body}} when is_binary(token) ->
          {:ok, tokens(body)}

        {:ok, %{status: status, body: body}} ->
          {:error, "the token endpoint answered #{status}: #{describe(body)}"}

        {:error, reason} ->
          {:error, "the token endpoint failed: #{Exception.message(reason)}"}
      end
    end
  end

  defp tokens(body) do
    %{access_token: body["access_token"]}
    |> put_if(:refresh_token, body["refresh_token"])
    |> put_if(:expires_at, expires_at(body["expires_in"]))
  end

  defp expires_at(seconds) when is_integer(seconds) and seconds > 0,
    do: DateTime.add(DateTime.utc_now(), seconds, :second)

  defp expires_at(seconds) when is_binary(seconds) do
    case Integer.parse(seconds) do
      {n, _} -> expires_at(n)
      :error -> nil
    end
  end

  defp expires_at(_), do: nil

  defp describe(%{"error" => error} = body) do
    [error, body["error_description"]] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
  end

  defp describe(body) when is_binary(body), do: String.slice(body, 0, 200)
  defp describe(body), do: body |> inspect() |> String.slice(0, 200)

  defp put_if(map, _key, nil), do: map
  defp put_if(map, _key, ""), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp fetch_by_id(id) do
    case Ash.get(Credential, id) do
      {:ok, %Credential{} = cred} -> {:ok, cred}
      {:error, _} -> {:error, "the credential is gone"}
    end
  end

  defp random(bytes),
    do: bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp challenge(verifier),
    do: :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

  defp with_query(url, query) do
    uri = URI.parse(url)
    existing = if uri.query, do: URI.decode_query(uri.query), else: %{}
    URI.to_string(%URI{uri | query: URI.encode_query(Map.merge(existing, query))})
  end
end
