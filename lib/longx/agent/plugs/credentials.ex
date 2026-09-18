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

  Longx keeps API keys and OAuth2 tokens for you, encrypted; you never see a value. `http_request` is only for a request that needs a credential — an authenticated API, an MCP server over HTTP (JSON-RPC POSTs); plain HTTP (a public page, an unauthenticated API, a download) stays with curl via exec_command or `web_fetch`, which follow redirects and keep the whole body. With a credential, use `http_request` with its name instead of curl: the service layer puts the value in the right header (or wherever `{{credential:NAME}}` stands in the URL, headers or body), refuses hosts the credential is not allowed for, refreshes an expired token first, and hands you the answer with the value redacted. `credentials_list` says what exists and whether it is ready. A credential that `needs_login` (OAuth2) is logged in with `credential_login`: the person does it in their browser, you wait. To add one, call `credential_create` — a key that is already on this machine (an environment variable, a .env or config file) is copied with `secret_from` (env:NAME, file:PATH, file:PATH#KEY) without you seeing it; otherwise the person types it into a masked field on the thread. `credential_rotate` replaces a key the same way. Never ask the person to paste a key into the chat, never print a secret with a command, never put one in a file or a message.
  """

  tool :credentials_list,
       "Lists the credentials Longx keeps: name, kind, status, allowed hosts, expiry — never a value.",
       namespace: @namespace do
  end

  tool :http_request,
       "An HTTP request with a credential injected by Longx (the value never reaches you). Only for a request that needs a credential — an authenticated API, an MCP server over HTTP (a JSON-RPC POST); a plain page or public API is curl via exec_command or web_fetch. The host must be one the credential allows; redirects are not followed and the body is clipped.",
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
       "Declares a new credential. The key (API key) or client secret (OAuth2) comes from the machine (secret_from) or is typed by the person into a masked field — you never see it. Give the hosts it may be sent to. OAuth2: never register a client yourself (its redirect URI would not be Longx's) — give registration_url, or a client_id the person got from the provider's console.",
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

    param :secret_from,
          :string,
          "Where the key / client secret already is on this machine, copied without you seeing it: env:NAME (an environment variable), file:PATH (the whole file, trimmed), file:PATH#KEY (a KEY=value / export KEY=… / KEY: value line, or a JSON key). Without it the person types the value into a masked field."
  end

  tool :credential_rotate,
       "Replaces the key (API key) or client secret (OAuth2) of an existing credential: from the machine with secret_from, else the person types the new value into a masked field.",
       namespace: @namespace,
       timeout: 600_000 do
    param :credential, :string, "The credential's name", required: true
    param :secret_from, :string, "env:NAME, file:PATH or file:PATH#KEY (see credential_create)"
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

  # a loopback redirect (no https public URL): a browser on the Longx machine
  # lands on Longx itself; one elsewhere lands on an unreachable 127.0.0.1
  # page whose address the person pastes back
  defp login_text(false), do: "在浏览器里完成登录；登录成功后这里会自动继续。"

  defp login_text(true),
    do:
      "在浏览器里完成登录。登录后浏览器会跳到 127.0.0.1 的地址：如果浏览器就在运行 Longx 的这台机器上，会自动继续；如果打不开（浏览器在别的机器上），把地址栏里的完整地址粘贴到下面。"

  defp redirect_field,
    do: %{id: "redirect", label: "登录后浏览器地址栏里的完整地址", required: false}

  def credential_login(%{"credential" => name}, ctx) do
    with {:ok, cred} <- fetch(name),
         :ok <- oauth2?(cred),
         {:ok, %{url: url, state: state, redirect_uri: redirect}} <-
           OAuth.begin_login(cred, thread_id: ctx.thread_id) do
      loopback? = OAuth.loopback?(redirect)

      case Context.ask(ctx,
             title: "登录 #{cred.label || cred.name}",
             text: login_text(loopback?),
             url: url,
             fields: if(loopback?, do: [redirect_field()], else: []),
             meta: %{"login" => state},
             timeout: 600_000
           ) do
        {:ok, %{"login" => "ok"}} ->
          logged_in(name)

        {:ok, %{"login" => "error", "message" => message}} ->
          {:error, "the login failed: #{message}"}

        {:ok, %{"redirect" => pasted}} when is_binary(pasted) and pasted != "" ->
          case OAuth.complete_url(pasted) do
            {:ok, _} -> logged_in(name)
            {:error, message} -> {:error, "the login did not complete: #{message}"}
          end

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
         {:ok, answer} <- obtain_secret(ctx, name, secret_field, args["secret_from"]),
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

  def credential_rotate(%{"credential" => name} = args, ctx) do
    with {:ok, cred} <- fetch(name),
         {:ok, field} <- rotate_field(cred),
         {:ok, answer} <- obtain_secret(ctx, name, field, args["secret_from"]),
         {:ok, _} <-
           Credentials.update_credential(cred, %{
             String.to_existing_atom(field.id) => answer[field.id]
           }) do
      {:ok, "credential #{name}: the #{field.label} was replaced"}
    else
      {:error, :no_agent} ->
        {:error, "the person has to type the secret: only inside an agent (or give secret_from)"}

      {:error, :cancelled} ->
        {:error, "the person cancelled"}

      {:error, :timeout} ->
        {:error, "no answer within the time"}

      {:error, message} when is_binary(message) ->
        {:error, message}

      {:error, other} ->
        {:error, "could not rotate: #{inspect(other)}"}
    end
  end

  def credential_rotate(_args, _ctx),
    do: {:error, "credential_rotate needs the credential's name"}

  # an empty answer to an optional field (a public OAuth2 client) is no secret
  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp blank_to_nil(value), do: value

  defp rotate_field(%{kind: :api_key}),
    do: {:ok, %{id: "secret", label: "API Key / Token", secret: true}}

  defp rotate_field(%{kind: :oauth2}),
    do: {:ok, %{id: "client_secret", label: "Client Secret", secret: true}}

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
        {:ok,
         %{id: "client_secret", label: "Client Secret（公开客户端留空）", secret: true, required: false}}

      true ->
        {:error,
         "an OAuth2 credential needs a client_id, or a registration_url the server offers"}
    end
  end

  defp secret_field(kind, _args), do: {:error, "unknown kind #{kind}"}

  # the value: nothing needed, copied from the machine (secret_from), or typed by the person
  defp obtain_secret(_ctx, _name, nil, _from), do: {:ok, %{}}

  defp obtain_secret(_ctx, _name, field, from) when is_binary(from) and from != "" do
    with {:ok, value} <- read_secret(from), do: {:ok, %{field.id => value}}
  end

  defp obtain_secret(ctx, name, field, _from), do: ask_secret(ctx, name, field)

  # env:NAME | file:PATH | file:PATH#KEY — read here, in the tool's task; the
  # model only ever gets "created" back
  defp read_secret("env:" <> name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> {:ok, String.trim(value)}
      _ -> {:error, "no environment variable #{name} (or it is empty)"}
    end
  end

  defp read_secret("file:" <> rest) do
    {path, key} =
      case String.split(rest, "#", parts: 2) do
        [path, key] -> {path, key}
        [path] -> {path, nil}
      end

    path = Path.expand(path)

    case File.read(path) do
      {:ok, content} -> secret_in(content, key, path)
      {:error, reason} -> {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp read_secret(other),
    do: {:error, "secret_from must be env:NAME, file:PATH or file:PATH#KEY, got #{other}"}

  defp secret_in(content, nil, path) do
    case String.trim(content) do
      "" -> {:error, "#{path} is empty"}
      value -> {:ok, value}
    end
  end

  defp secret_in(content, key, path) do
    json =
      case Jason.decode(content) do
        {:ok, %{} = map} -> map[key]
        _ -> nil
      end

    line =
      Regex.run(~r/^\s*(?:export\s+)?#{Regex.escape(key)}\s*[=:]\s*(.+?)\s*,?\s*$/m, content,
        capture: :all_but_first
      )

    cond do
      is_binary(json) and json != "" -> {:ok, json}
      match?([_], line) -> {:ok, line |> hd() |> String.trim() |> unquote_value()}
      true -> {:error, "no #{key} in #{path}"}
    end
  end

  defp unquote_value(value) do
    case value do
      <<q, rest::binary>> when q in [?", ?'] -> String.trim_trailing(rest, <<q>>)
      _ -> value
    end
  end

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
      |> put_if(:client_secret, field && blank_to_nil(answer[field.id]))
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
