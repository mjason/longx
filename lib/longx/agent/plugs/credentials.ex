defmodule Longx.Agent.Plugs.Credentials do
  @moduledoc """
  Credentials for the agent, without the secrets: `credentials_list`
  (names, kinds, statuses, hosts — never a value), `http_request`
  (a request the service layer makes with the named credential injected,
  to an allowed host only, the answer scrubbed — `Longx.Credentials.
  request/4`), `credential_login` (an OAuth2 login the person completes in
  the browser; the tool waits on an ask and learns only that it worked)
  and `credential_create` (declares one; the key or client secret is
  typed by the person into the ask's masked field and stored by the tool
  — it never passes through the model). Namespace `longx`.
  """

  use Longx.Agent.Plug

  alias Longx.Credentials
  alias Longx.Credentials.OAuth

  @namespace "longx"
  # a response body is clipped like a command's output: head and tail kept
  @body_cap 32_000

  instructions """
  # Credentials

  Longx keeps API keys and OAuth2 tokens for you, encrypted; you never see a value. To call an authenticated API — an HTTP API, an MCP server over HTTP (JSON-RPC POSTs) — use `http_request` with the credential's name instead of curl: the service layer puts the value in the right header (or wherever `{{credential:NAME}}` stands in the URL, headers or body), refuses hosts the credential is not allowed for, refreshes an expired token first, and hands you the answer with the value redacted. `credentials_list` says what exists and whether it is ready. A credential that `needs_login` (OAuth2) is logged in with `credential_login`: the person does it in their browser, you wait. To add one, call `credential_create` — the person types the key into a masked field on the thread; never ask them to paste a key into the chat, never put a secret in a command, a file or a message.
  """

  tool :credentials_list,
       "Lists the credentials Longx keeps: name, kind, status, allowed hosts, expiry — never a value.",
       namespace: @namespace do
  end

  tool :http_request,
       "An HTTP request with a credential injected by Longx (the value never reaches you). Use it for every authenticated API and for MCP servers over HTTP (a JSON-RPC POST). The host must be one the credential allows.",
       namespace: @namespace,
       timeout: 300_000 do
    param :credential, :string, "The credential's name (credentials_list)", required: true
    param :url, :string, "The full URL (https://…)", required: true

    param :method,
          {:enum, ~w(GET POST PUT PATCH DELETE HEAD OPTIONS)},
          "HTTP method, GET by default"

    param :headers,
          :map,
          "Extra headers ({\"content-type\": \"application/json\"}); the credential's own header is added for you"

    param :body, :string, "The request body as text (JSON for an API)"
    param :timeout_ms, :integer, "Give up after this many ms (60000 by default, 300000 at most)"
  end

  tool :credential_login,
       "Logs an OAuth2 credential in: the person completes the login in their browser through Longx; you wait and learn only whether it worked.",
       namespace: @namespace,
       timeout: 900_000 do
    param :credential, :string, "The credential's name", required: true
  end

  tool :credential_create,
       "Declares a new credential. The key (API key) or client secret (OAuth2) is typed by the person into a masked field — you never see it. Give the hosts it may be sent to.",
       namespace: @namespace,
       timeout: 600_000 do
    param :name, :string, "A short lowercase slug (coros, github, …)", required: true
    param :kind, {:enum, ~w(api_key oauth2)}, "api_key or oauth2", required: true

    param :allowed_hosts,
          {:array, :string},
          "The hostnames the credential may be sent to (api.example.com); required",
          required: true

    param :label, :string, "A human label"
    param :header, :string, "The header carrying the value (authorization by default)"

    param :scheme,
          :string,
          "What precedes the value in the header: Bearer by default, \"\" for the raw value"

    param :authorize_url, :string, "OAuth2: the authorization endpoint"
    param :token_url, :string, "OAuth2: the token endpoint"
    param :scopes, :string, "OAuth2: the scopes, space separated"
    param :client_id, :string, "OAuth2: the client id, when the provider gave one"

    param :registration_url,
          :string,
          "OAuth2: an RFC 7591 registration endpoint — Longx registers itself, no client id needed"
  end

  ## the tools

  def credentials_list(_args, _ctx) do
    case Credentials.list() do
      [] ->
        {:ok,
         "no credentials yet — credential_create declares one (the person types the value), or the person adds one in Settings → 凭证"}

      creds ->
        lines =
          Enum.map(creds, fn c ->
            "- #{c.name} (#{c.kind}, #{c.status})#{label(c)} — hosts: #{Enum.join(c.allowed_hosts, ", ")}#{expiry(c)}#{error(c)}"
          end)

        {:ok, Enum.join(lines, "\n")}
    end
  end

  def http_request(%{"credential" => name, "url" => url} = args, _ctx) do
    opts = [
      headers: args["headers"] || %{},
      body: args["body"],
      timeout_ms:
        args["timeout_ms"] |> then(&if(is_integer(&1), do: min(&1, 300_000), else: 60_000))
    ]

    case Credentials.request(name, args["method"] || "GET", url, opts) do
      {:ok, %{status: status, headers: headers, body: body}} ->
        head = "HTTP #{status}" <> content_type(headers)
        {:ok, head <> "\n\n" <> clip(body)}

      {:error, reason} ->
        {:error, explain(reason, name)}
    end
  end

  def http_request(_args, _ctx), do: {:error, "http_request needs credential and url"}

  def credential_login(%{"credential" => name}, ctx) do
    with {:ok, cred} <- fetch(name),
         :ok <- oauth2?(cred),
         {:ok, %{url: url, state: state}} <- OAuth.begin_login(cred, thread_id: ctx.thread_id) do
      case Context.ask(ctx,
             title: "登录 #{cred.label || cred.name}",
             text: "在浏览器里完成登录；登录成功后这里会自动继续。",
             url: url,
             meta: %{"login" => state},
             timeout: 600_000
           ) do
        {:ok, %{"login" => "ok"}} ->
          logged_in(name)

        {:ok, %{"login" => "error", "message" => message}} ->
          {:error, "the login failed: #{message}"}

        {:ok, _pressed_done} ->
          if_logged_in(name)

        {:error, :cancelled} ->
          {:error, "the person cancelled the login"}

        {:error, :timeout} ->
          {:error, "no login within the time"}

        {:error, :no_agent} ->
          {:error, "a login needs the person: only inside an agent"}
      end
    else
      {:error, message} when is_binary(message) -> {:error, message}
    end
  end

  def credential_create(%{"name" => name, "kind" => kind} = args, ctx) do
    hosts = List.wrap(args["allowed_hosts"])

    with {:ok, secret_field} <- secret_field(kind, args),
         {:ok, answer} <- ask_secret(ctx, name, secret_field),
         {:ok, cred} <- create(kind, args, hosts, secret_field, answer) do
      {:ok,
       "credential #{cred.name} created (#{cred.kind}; hosts: #{Enum.join(cred.allowed_hosts, ", ")}; status: #{status_of(cred.name)})" <>
         if(cred.kind == :oauth2 and status_of(cred.name) == :needs_login,
           do: " — run credential_login to log it in",
           else: ""
         )}
    else
      {:error, :no_agent} ->
        {:error, "the person has to type the secret: only inside an agent"}

      {:error, :cancelled} ->
        {:error, "the person cancelled"}

      {:error, :timeout} ->
        {:error, "no answer within the time"}

      {:error, %Ash.Error.Invalid{} = invalid} ->
        {:error, "invalid: " <> Exception.message(invalid)}

      {:error, message} when is_binary(message) ->
        {:error, message}

      {:error, other} ->
        {:error, "could not create: #{inspect(other)}"}
    end
  end

  def credential_create(_args, _ctx),
    do: {:error, "credential_create needs name, kind and allowed_hosts"}

  ## pieces

  defp fetch(name) do
    case Credentials.fetch(name) do
      {:ok, cred} -> {:ok, cred}
      {:error, :not_found} -> {:error, "no credential named #{name} (see credentials_list)"}
    end
  end

  defp oauth2?(%{kind: :oauth2}), do: :ok
  defp oauth2?(%{name: name}), do: {:error, "#{name} is an API key, nothing to log in"}

  defp logged_in(name) do
    case Credentials.fetch(name) do
      {:ok, %{expires_at: %DateTime{} = at}} ->
        {:ok, "logged in; the token expires at #{DateTime.to_iso8601(at)} and Longx refreshes it"}

      _ ->
        {:ok, "logged in"}
    end
  end

  # 已完成 pressed: the login may still be in flight, or never happened
  defp if_logged_in(name) do
    case Credentials.fetch(name) do
      {:ok, %{status: :ready}} ->
        logged_in(name)

      {:ok, %{status: status}} ->
        {:error, "the login did not complete (status: #{status}); try credential_login again"}

      _ ->
        {:error, "the credential is gone"}
    end
  end

  # which secret the person must type, if any
  defp secret_field("api_key", _args),
    do: {:ok, %{id: "secret", label: "API Key / Token", secret: true}}

  defp secret_field("oauth2", args) do
    cond do
      present?(args["registration_url"]) ->
        {:ok, nil}

      present?(args["client_id"]) ->
        {:ok, %{id: "client_secret", label: "Client Secret（公开客户端留空）", secret: true}}

      true ->
        {:error,
         "an OAuth2 credential needs a client_id, or a registration_url the server offers"}
    end
  end

  defp secret_field(kind, _args), do: {:error, "unknown kind #{kind}"}

  defp ask_secret(_ctx, _name, nil), do: {:ok, %{}}

  defp ask_secret(ctx, name, field) do
    Context.ask(ctx,
      title: "输入凭证 #{name} 的密钥",
      text: "值只存在 Longx 里，agent 看不到。",
      fields: [field],
      timeout: 600_000
    )
  end

  defp create("api_key", args, hosts, field, answer) do
    Credentials.create_api_key(
      %{name: args["name"], label: args["label"], allowed_hosts: hosts, secret: answer[field.id]}
      |> put_if(:header, args["header"])
      |> put_if(:scheme, args["scheme"])
    )
  end

  defp create("oauth2", args, hosts, field, answer) do
    Credentials.create_oauth2(
      %{
        name: args["name"],
        label: args["label"],
        allowed_hosts: hosts,
        authorize_url: args["authorize_url"],
        token_url: args["token_url"],
        scopes: args["scopes"],
        client_id: args["client_id"],
        registration_url: args["registration_url"]
      }
      |> put_if(:client_secret, field && answer[field.id])
      |> put_if(:header, args["header"])
      |> put_if(:scheme, args["scheme"])
    )
  end

  defp status_of(name) do
    case Credentials.fetch(name) do
      {:ok, %{status: status}} -> status
      _ -> :unknown
    end
  end

  defp explain(:not_found, name), do: "no credential named #{name} (see credentials_list)"

  defp explain(:needs_login, name),
    do:
      "credential #{name} has no value yet: credential_login (OAuth2), or the person enters it in Settings → 凭证"

  defp explain(:expired, name),
    do: "credential #{name} has expired and cannot be refreshed: credential_login again"

  defp explain({:refresh_failed, message}, name),
    do: "credential #{name} could not be refreshed: #{message}"

  defp explain({:host_not_allowed, host}, name) do
    hosts =
      case Credentials.fetch(name) do
        {:ok, cred} -> Enum.join(cred.allowed_hosts, ", ")
        _ -> "?"
      end

    "credential #{name} is not allowed to be sent to #{host} (allowed hosts: #{hosts})"
  end

  defp explain({:bad_url, url}, _name), do: "not a URL: #{url}"
  defp explain({:bad_method, m}, _name), do: "unknown method #{m}"
  defp explain({:transport, message}, _name), do: "the request failed: #{message}"

  defp content_type(headers) do
    case headers["content-type"] do
      type when is_binary(type) -> " · " <> type
      _ -> ""
    end
  end

  defp clip(body) when byte_size(body) <= @body_cap, do: body

  defp clip(body) do
    half = div(@body_cap, 2)
    head = binary_part(body, 0, half)
    tail = binary_part(body, byte_size(body) - half, half)
    head <> "\n\n[… #{byte_size(body) - @body_cap} bytes truncated …]\n\n" <> tail
  end

  defp label(%{label: label}) when is_binary(label) and label != "", do: " “#{label}”"
  defp label(_), do: ""

  defp expiry(%{expires_at: %DateTime{} = at}), do: "; expires #{DateTime.to_iso8601(at)}"
  defp expiry(_), do: ""

  defp error(%{status: :error, last_error: e}) when is_binary(e), do: "; last error: #{e}"
  defp error(_), do: ""

  defp present?(v), do: is_binary(v) and v != ""

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
end
