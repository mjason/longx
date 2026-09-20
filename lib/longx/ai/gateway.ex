defmodule Longx.AI.Gateway do
  @moduledoc """
  Prepares a Responses API request for the configured upstream — what the
  kernel's `Longx.Agent.Model` runs before every call. A request names the
  placeholder model (`longx`, the default) or a slug and carries the full
  conversation (`store: false`), so this is stateless: `prepare/2` rewrites
  the request for the `Longx.AI.Target` (model id, reasoning items sanitised
  per provider, the output cap, provider-hosted tools kept or dropped).
  """

  alias Longx.AI.Gateway.Limiter
  alias Longx.AI.Target

  require Logger

  defmodule Upstream do
    @moduledoc false
    @enforce_keys [:url, :headers, :body]
    defstruct [
      :url,
      :headers,
      :body,
      :provider_slug,
      kind: :openai_compatible,
      degraded?: false,
      receive_timeout: :timer.minutes(10),
      max_concurrent: nil
    ]

    @type t :: %__MODULE__{
            url: String.t(),
            headers: [{String.t(), String.t()}],
            body: map,
            provider_slug: String.t() | nil,
            kind: :openai | :openai_compatible,
            degraded?: boolean,
            receive_timeout: pos_integer,
            max_concurrent: pos_integer | nil
          }
  end

  # Not part of the public Responses API; codex-internal telemetry.
  @internal_fields ["client_metadata"]

  # The Responses API's provider-hosted search tools (run inside OpenAI).
  @hosted_search_tools ["web_search", "web_search_preview"]

  @doc """
  Rewrites a Responses request for `target`: the placeholder model is
  replaced and streaming is forced since the kernel only reads SSE.

  Function tools pass through untouched — which tools the agent offers is
  the pipeline's decision, not this module's. The one exception is the provider-hosted
  `web_search` tool: it only exists inside providers that run it, so it is
  dropped for any other target instead of failing the whole request.
  """
  @spec prepare(term, Target.t()) :: {:ok, Upstream.t()} | {:error, :invalid_request}
  def prepare(%{"input" => input} = body, %Target{} = target) when is_list(input) do
    body =
      body
      |> Map.drop(@internal_fields)
      |> Map.put("model", target.model)
      |> Map.put("stream", true)
      |> Map.put(
        "input",
        input
        |> sanitize_reasoning(target.kind)
        |> sanitize_ids(target.kind)
        |> translate_agent_messages(target.kind)
        |> sanitize_reasoning(target.kind)
        |> translate_agent_messages(target.kind)
        |> strip_output_fields(target)
      )
      |> drop_hosted_search(target)
      |> put_image_generation(target)
      |> drop_hosted_calls(target)
      |> put_max_output_tokens(target)
      |> put_reasoning_summary(target)
      |> shape_chatgpt(target)
      |> dump_request()

    {:ok,
     %Upstream{
       url: String.trim_trailing(target.base_url, "/") <> "/responses",
       headers:
         [
           {"authorization", "Bearer " <> target.api_key},
           {"content-type", "application/json"},
           {"accept", "text/event-stream"}
         ] ++ chatgpt_headers(target),
       body: body,
       provider_slug: target.provider_slug,
       kind: target.kind,
       receive_timeout: target.request_timeout_ms,
       max_concurrent: target.max_concurrent_requests
     }}
  end

  def prepare(_body, _target), do: {:error, :invalid_request}

  # the Codex backend (a ChatGPT subscription) keeps nothing server-side: every
  # request says `store: false` and asks the reasoning back encrypted so the next
  # step can replay it; the headers are what the Codex CLI sends — the backend
  # answers only a known originator
  defp shape_chatgpt(body, %{chatgpt?: true}) do
    body
    |> Map.put("store", false)
    |> Map.put("include", ["reasoning.encrypted_content"])
  end

  defp shape_chatgpt(body, _target), do: body

  defp chatgpt_headers(%{chatgpt?: true} = target) do
    [
      {"openai-beta", "responses=experimental"},
      {"originator", "codex_cli_rs"}
    ] ++ if(target.account_id, do: [{"chatgpt-account-id", target.account_id}], else: [])
  end

  defp chatgpt_headers(_target), do: []

  # dev aid: `config :longx, Longx.AI.Gateway, dump_requests_to: dir` writes every
  # prepared request as JSON (what the model actually sees — the way to check
  # what codex put in front of it, sub-agent envelopes included)
  defp dump_request(body) do
    case Application.get_env(:longx, __MODULE__, [])[:dump_requests_to] do
      nil ->
        body

      dir ->
        File.mkdir_p!(dir)
        name = "#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}.json"
        File.write!(Path.join(dir, name), Jason.encode!(body, pretty: true))
        body
    end
  end

  # The model's output cap, unless codex asked for one itself.
  defp put_max_output_tokens(body, %Target{max_output_tokens: nil}), do: body

  defp put_max_output_tokens(body, %Target{max_output_tokens: max}),
    do: Map.put_new(body, "max_output_tokens", max)

  # a `web_search_call` item is the searching provider's own: replayed to
  # another it is an unknown item type (the model's message that followed
  # carries what it found)
  @hosted_call_items ["web_search_call", "image_generation_call"]

  defp drop_hosted_calls(body, %Target{hosted_web_search?: true}), do: body

  defp drop_hosted_calls(%{"input" => input} = body, _target) when is_list(input),
    do: Map.put(body, "input", Enum.reject(input, &(&1["type"] in @hosted_call_items)))

  defp drop_hosted_calls(body, _target), do: body

  # the row's reasoning summary on the request's reasoning block (the kernel
  # sends `auto`): `none` drops the key — OpenAI's way to ask for no summary
  defp put_reasoning_summary(%{"reasoning" => %{} = reasoning} = body, %Target{
         reasoning_summary: choice
       })
       when choice in [:auto, :concise, :detailed] do
    Map.put(body, "reasoning", Map.put(reasoning, "summary", Atom.to_string(choice)))
  end

  defp put_reasoning_summary(%{"reasoning" => %{} = reasoning} = body, %Target{
         reasoning_summary: :none
       }),
       do: Map.put(body, "reasoning", Map.delete(reasoning, "summary"))

  defp put_reasoning_summary(body, _target), do: body

  # the provider's hosted image_generation tool, for a model flagged for it —
  # always the same entry, so the request's prefix stays stable; off it goes
  # for every other target
  @image_tool %{"type" => "image_generation"}

  defp put_image_generation(%{"tools" => tools} = body, %Target{image_generation?: true})
       when is_list(tools) do
    if Enum.any?(tools, &(&1["type"] == "image_generation")),
      do: body,
      else: Map.put(body, "tools", tools ++ [@image_tool])
  end

  defp put_image_generation(body, %Target{image_generation?: true}),
    do: Map.put(body, "tools", [@image_tool])

  defp put_image_generation(%{"tools" => tools} = body, _target) when is_list(tools),
    do: Map.put(body, "tools", Enum.reject(tools, &(&1["type"] == "image_generation")))

  defp put_image_generation(body, _target), do: body

  defp drop_hosted_search(body, %Target{hosted_web_search?: true}), do: body

  defp drop_hosted_search(%{"tools" => tools} = body, _target) when is_list(tools),
    do: Map.put(body, "tools", Enum.reject(tools, &(&1["type"] in @hosted_search_tools)))

  defp drop_hosted_search(body, _target), do: body

  ## Sub-agent envelopes: readable for everyone

  # codex hands a spawned sub-agent its task as an `agent_message` item whose
  # payload is an `encrypted_content` part — plain text, but a content type
  # only OpenAI's Responses API knows; any other provider ignores it and the
  # child starts with an empty task. For those targets the item becomes an
  # ordinary user message with the payload as text.
  @spec translate_agent_messages([map], :openai | :openai_compatible) :: [map]
  def translate_agent_messages(input, :openai), do: input

  def translate_agent_messages(input, _kind) do
    Enum.map(input, fn
      %{"type" => "agent_message", "content" => content} when is_list(content) ->
        %{"type" => "message", "role" => "user", "content" => Enum.map(content, &readable_part/1)}

      item ->
        item
    end)
  end

  defp readable_part(%{"type" => "encrypted_content", "encrypted_content" => text})
       when is_binary(text),
       do: %{"type" => "input_text", "text" => text}

  defp readable_part(part), do: part

  ## Reasoning items: a provider only ever receives its own opaque data

  # `reasoning.encrypted_content` is a black box only its producer can read
  # (OpenAI: real ciphertext; DeepSeek & co.: a reference token they ignore on
  # input). Whatever the target, nothing produced elsewhere crosses the
  # gateway: OpenAI gets only its own `rs_` items intact, everyone else gets
  # none at all. Readable summaries / reasoning text stay; an item left with
  # nothing readable is dropped.
  @openai_reasoning_prefix "rs_"

  @spec sanitize_reasoning([map], :openai | :openai_compatible) :: [map]
  def sanitize_reasoning(input, kind) do
    Enum.flat_map(input, fn
      %{"type" => "reasoning"} = item -> sanitize_reasoning_item(item, kind)
      item -> [item]
    end)
  end

  defp sanitize_reasoning_item(%{"id" => @openai_reasoning_prefix <> _} = item, :openai),
    do: [item]

  defp sanitize_reasoning_item(item, _kind), do: without_encrypted(item)

  defp without_encrypted(item), do: item |> Map.delete("encrypted_content") |> keep_if_readable()

  defp keep_if_readable(item) do
    if readable?(item["summary"]) or readable?(item["content"]), do: [item], else: []
  end

  defp readable?(parts) when is_list(parts),
    do: Enum.any?(parts, &(is_map(&1) and is_binary(&1["text"]) and &1["text"] != ""))

  defp readable?(text) when is_binary(text), do: text != ""
  defp readable?(_), do: false

  ## Item ids: a reference only the producer can resolve

  # An input item's `id` names the provider's own stored copy of it. DeepSeek
  # writes bare uuids and takes anything back; 百炼 writes `msg_<uuid>` on every
  # kind and refuses a *message* whose id lacks the `msg_` prefix (a thread that
  # ran on DeepSeek and switched to qwen failed every turn with 400); OpenAI
  # writes `msg_` / `fc_` / `rs_` + hex and looks the id up. Both third parties
  # take an item without an id, so a target other than OpenAI gets none, and
  # OpenAI gets only ids of its own shape (a prefix and no dashes — 百炼's
  # `msg_<uuid>` is not one of its). Verified live on DeepSeek and 百炼.
  @openai_id_prefixes ["msg_", "fc_", "rs_", "ws_", "ctc_", "amsg_"]

  @spec sanitize_ids([map], :openai | :openai_compatible) :: [map]
  def sanitize_ids(input, :openai_compatible), do: Enum.map(input, &Map.delete(&1, "id"))

  def sanitize_ids(input, :openai) do
    Enum.map(input, fn
      %{"id" => id} = item when is_binary(id) ->
        if openai_id?(id), do: item, else: Map.delete(item, "id")

      item ->
        item
    end)
  end

  defp openai_id?(id) do
    Enum.any?(@openai_id_prefixes, fn prefix ->
      case id do
        ^prefix <> rest -> rest != "" and not String.contains?(rest, "-")
        _ -> false
      end
    end)
  end

  # the Codex backend refuses an input item carrying what only an output item
  # has (`status`, `phase`, a part's `logprobs`): "Unknown parameter:
  # 'input[1].status'" — api.openai.com takes them, so only that target is cleaned
  @output_only_item_keys ["status", "phase"]
  @output_only_part_keys ["logprobs"]

  defp strip_output_fields(input, %Target{chatgpt?: true}) do
    # every item: a reasoning item carries a status too — and the backend takes
    # a reasoning item only as its own (`rs_` + ciphertext) with an empty
    # `content`: another provider's readable reasoning ("Invalid
    # 'input[1].content': array too long") goes, its own loses `content`
    input
    |> Enum.filter(fn
      %{"type" => "reasoning"} = item -> own_reasoning?(item)
      _ -> true
    end)
    |> Enum.map(fn
      %{"type" => "reasoning"} = item -> Map.delete(item, "content")
      item -> item
    end)
    |> Enum.map(fn item when is_map(item) ->
      item
      |> Map.drop(@output_only_item_keys)
      |> Map.update("content", nil, fn
        parts when is_list(parts) ->
          Enum.map(parts, &if(is_map(&1), do: Map.drop(&1, @output_only_part_keys), else: &1))

        other ->
          other
      end)
      |> then(&if(is_nil(&1["content"]), do: Map.delete(&1, "content"), else: &1))
    end)
  end

  defp strip_output_fields(input, _target), do: input

  defp own_reasoning?(%{"id" => @openai_reasoning_prefix <> _, "encrypted_content" => enc})
       when is_binary(enc) and enc != "",
       do: true

  defp own_reasoning?(_item), do: false

  @doc "The degraded form of a request: no encrypted reasoning at all, not even the target's own."
  @spec strip_all_encrypted(map) :: map
  def strip_all_encrypted(%{"input" => input} = body) when is_list(input) do
    Map.put(
      body,
      "input",
      Enum.flat_map(input, fn
        %{"type" => "reasoning"} = item -> without_encrypted(item)
        item -> [item]
      end)
    )
  end

  def strip_all_encrypted(body), do: body

  @doc """
  Performs the upstream request and relays the response into `conn`.

  * 200 → chunked `text/event-stream`, bytes forwarded as they arrive
  * other status → forwarded as-is (codex surfaces the upstream error message)
  * transport failure → 502
  """
  @spec stream(Upstream.t(), Plug.Conn.t()) :: Plug.Conn.t()
  def stream(%Upstream{} = up, conn) do
    # the slot covers the whole relay; a retry (degraded) happens inside it
    case Limiter.run(up.provider_slug, up.max_concurrent, fn -> relay_upstream(up, conn) end) do
      {:ok, conn} ->
        conn

      :busy ->
        Logger.info(
          "ai gateway: provider #{up.provider_slug} at its limit of #{up.max_concurrent} concurrent requests"
        )

        conn
        |> Plug.Conn.put_resp_header("retry-after", "1")
        |> error(
          429,
          "provider #{up.provider_slug} is at its limit of #{up.max_concurrent} concurrent requests"
        )
    end
  end

  defp relay_upstream(%Upstream{} = up, conn) do
    request =
      Req.new(
        url: up.url,
        headers: up.headers,
        json: up.body,
        retry: false,
        receive_timeout: up.receive_timeout,
        into: :self
      )

    case Req.post(request) do
      {:ok, %Req.Response{status: 200} = resp} ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.put_resp_header("cache-control", "no-cache")
        |> Plug.Conn.send_chunked(200)
        |> relay(resp, up.receive_timeout)

      {:ok, %Req.Response{status: status} = resp} ->
        body = collect(resp)

        if retry_without_reasoning?(up, status, body) do
          # OpenAI could not use the reasoning we replayed (rotated key, expired,
          # model change…): once more without any encrypted reasoning. The
          # conversation is intact; only reasoning continuity is lost this once.
          Logger.warning(
            "ai gateway: OpenAI rejected replayed reasoning (#{String.slice(body, 0, 200)}); retrying without encrypted reasoning"
          )

          relay_upstream(
            %Upstream{up | body: strip_all_encrypted(up.body), degraded?: true},
            conn
          )
        else
          Logger.warning(
            "ai gateway: upstream #{up.url} answered #{status}: #{String.slice(body, 0, 500)}"
          )

          remember_auth_error(up, status, body)

          conn
          |> Plug.Conn.put_resp_content_type(content_type(resp))
          |> Plug.Conn.send_resp(status, body)
        end

      {:error, %Req.TransportError{reason: :timeout}} ->
        Logger.error("ai gateway: upstream #{up.url} timed out after #{up.receive_timeout}ms")

        error(
          conn,
          504,
          "upstream timed out after #{up.receive_timeout}ms (provider request_timeout_ms)"
        )

      {:error, exception} ->
        Logger.error(
          "ai gateway: upstream #{up.url} unreachable: #{Exception.message(exception)}"
        )

        error(conn, 502, "upstream request failed: #{Exception.message(exception)}")
    end
  end

  # A refused key is worth surfacing in the UI, not only in a log line.
  defp remember_auth_error(%Upstream{provider_slug: slug}, status, body)
       when is_binary(slug) and status in [401, 403] do
    with {:ok, provider} <- Longx.AI.get_provider_by_slug(slug) do
      Longx.AI.record_provider_error(provider, "#{status} #{String.slice(body, 0, 200)}")
    end

    :ok
  end

  defp remember_auth_error(_up, _status, _body), do: :ok

  # Only OpenAI, only once, only when the error is about the reasoning we sent.
  defp retry_without_reasoning?(%Upstream{kind: :openai, degraded?: false}, status, body)
       when status in 400..422 do
    body =~ ~r/encrypted|reasoning/i
  end

  defp retry_without_reasoning?(_up, _status, _body), do: false

  @doc "Sends a Responses-style JSON error."
  @spec error(Plug.Conn.t(), pos_integer, String.t()) :: Plug.Conn.t()
  def error(conn, status, message) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(
      status,
      Jason.encode!(%{error: %{message: message, type: "gateway_error"}})
    )
  end

  # Only consume this response's messages (`{ref, _}`); anything else in the
  # connection process's mailbox is not ours to touch.
  defp relay(conn, %Req.Response{body: %Req.Response.Async{ref: ref}} = resp, idle_timeout) do
    receive do
      {^ref, _} = message ->
        case Req.parse_message(resp, message) do
          {:ok, chunks} ->
            relay_chunks(conn, resp, chunks, idle_timeout)

          {:error, reason} ->
            Logger.warning("ai gateway: upstream stream error: #{inspect(reason)}")
            conn
        end
    after
      idle_timeout ->
        Logger.warning("ai gateway: upstream stream idle for #{idle_timeout}ms; closing")
        Req.cancel_async_response(resp)
        conn
    end
  end

  # A message may carry several chunks; keep receiving until :done or the
  # client goes away.
  defp relay_chunks(conn, resp, [], idle_timeout), do: relay(conn, resp, idle_timeout)

  defp relay_chunks(conn, resp, [{:data, data} | rest], idle_timeout) do
    case Plug.Conn.chunk(conn, data) do
      {:ok, conn} ->
        relay_chunks(conn, resp, rest, idle_timeout)

      {:error, _closed} ->
        Req.cancel_async_response(resp)
        conn
    end
  end

  defp relay_chunks(conn, _resp, [:done | _], _idle_timeout), do: conn

  defp relay_chunks(conn, resp, [{:trailers, _} | rest], idle_timeout),
    do: relay_chunks(conn, resp, rest, idle_timeout)

  # Non-200 bodies are small JSON errors: gather them whole.
  defp collect(%Req.Response{body: %Req.Response.Async{ref: ref}} = resp, acc \\ []) do
    receive do
      {^ref, _} = message ->
        case Req.parse_message(resp, message) do
          {:ok, chunks} ->
            acc = datas(chunks) ++ acc
            if :done in chunks, do: finish(acc), else: collect(resp, acc)

          {:error, _} ->
            finish(acc)
        end
    after
      5_000 ->
        Req.cancel_async_response(resp)
        finish(acc)
    end
  end

  defp finish(acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp datas(chunks), do: for({:data, d} <- chunks, do: d) |> Enum.reverse()

  defp content_type(%Req.Response{} = resp) do
    case Req.Response.get_header(resp, "content-type") do
      [ct | _] -> ct
      [] -> "application/json"
    end
  end
end
