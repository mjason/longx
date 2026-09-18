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

  @doc "The redirect URI logins use: the browser's origin when given, else the public URL."
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

    String.trim_trailing(base, "/") <> @callback_path
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
    redirect = redirect_uri(Keyword.get(opts, :origin))

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
        %{
          "response_type" => "code",
          "client_id" => cred.client_id,
          "redirect_uri" => redirect,
          "state" => state
        }
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

  # A client the server refuses outright (an authorize probe answering 400 —
  # a client registered elsewhere, with another redirect URI, is the usual
  # case: an agent once registered one by hand and handed over the id) is
  # replaced by one Longx registers itself, at the row's registration URL or
  # the one the server's RFC 8414 metadata names. No way to register, or a
  # probe that fails for another reason: the login goes on as it is.
  defp accepted_client(%Credential{} = cred, redirect) do
    case probe_authorize(cred, redirect) do
      :rejected ->
        case registration_url(cred) do
          nil ->
            {:ok, cred}

          url ->
            with {:ok, cred} <- Credentials.update_credential(cred, %{registration_url: url}),
                 {:ok, cred} <- register(cred, redirect) do
              {:ok, cred}
            else
              _ -> {:ok, cred}
            end
        end

      _ ->
        {:ok, cred}
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
