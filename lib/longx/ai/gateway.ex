defmodule Longx.AI.Gateway do
  @moduledoc """
  Forwards a Responses API request from codex to the configured upstream.

  Codex is configured with a single provider (`longx`) and a placeholder model
  (`longx`); every request lands here carrying the full conversation
  (`store: false`), so the gateway is stateless: `prepare/2` rewrites the
  request for the `Longx.AI.Target` and `stream/2` relays the upstream SSE
  stream chunk by chunk into the Plug connection.
  """

  alias Longx.AI.Target

  require Logger

  defmodule Upstream do
    @moduledoc false
    @enforce_keys [:url, :headers, :body]
    defstruct [:url, :headers, :body, kind: :openai_compatible, degraded?: false]

    @type t :: %__MODULE__{
            url: String.t(),
            headers: [{String.t(), String.t()}],
            body: map,
            kind: :openai | :openai_compatible,
            degraded?: boolean
          }
  end

  # Not part of the public Responses API; codex-internal telemetry.
  @internal_fields ["client_metadata"]

  # Codex may need minutes of silence while a model thinks.
  @receive_timeout :timer.minutes(10)

  @doc """
  Rewrites a codex Responses request for `target`: the placeholder model is
  replaced and streaming is forced since `stream/2` only speaks SSE.

  Tools are passed through untouched. Which tools codex offers is decided in
  its config (`Longx.Codex.Home`), not here: DeepSeek/GLM accept `namespace`
  tools (sub-agents, `web.run`), and OpenAI's hosted `web_search` is never
  emitted because standalone search is used instead.
  """
  @spec prepare(term, Target.t()) :: {:ok, Upstream.t()} | {:error, :invalid_request}
  def prepare(%{"input" => input} = body, %Target{} = target) when is_list(input) do
    body =
      body
      |> Map.drop(@internal_fields)
      |> Map.put("model", target.model)
      |> Map.put("stream", true)
      |> Map.put("input", sanitize_reasoning(input, target.kind))

    {:ok,
     %Upstream{
       url: String.trim_trailing(target.base_url, "/") <> "/responses",
       headers: [
         {"authorization", "Bearer " <> target.api_key},
         {"content-type", "application/json"},
         {"accept", "text/event-stream"}
       ],
       body: body,
       kind: target.kind
     }}
  end

  def prepare(_body, _target), do: {:error, :invalid_request}

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
    request =
      Req.new(
        url: up.url,
        headers: up.headers,
        json: up.body,
        retry: false,
        receive_timeout: @receive_timeout,
        into: :self
      )

    case Req.post(request) do
      {:ok, %Req.Response{status: 200} = resp} ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.put_resp_header("cache-control", "no-cache")
        |> Plug.Conn.send_chunked(200)
        |> relay(resp)

      {:ok, %Req.Response{status: status} = resp} ->
        body = collect(resp)

        if retry_without_reasoning?(up, status, body) do
          # OpenAI could not use the reasoning we replayed (rotated key, expired,
          # model change…): once more without any encrypted reasoning. The
          # conversation is intact; only reasoning continuity is lost this once.
          Logger.warning(
            "ai gateway: OpenAI rejected replayed reasoning (#{String.slice(body, 0, 200)}); retrying without encrypted reasoning"
          )

          stream(%Upstream{up | body: strip_all_encrypted(up.body), degraded?: true}, conn)
        else
          Logger.warning(
            "ai gateway: upstream #{up.url} answered #{status}: #{String.slice(body, 0, 500)}"
          )

          conn
          |> Plug.Conn.put_resp_content_type(content_type(resp))
          |> Plug.Conn.send_resp(status, body)
        end

      {:error, exception} ->
        Logger.error(
          "ai gateway: upstream #{up.url} unreachable: #{Exception.message(exception)}"
        )

        error(conn, 502, "upstream request failed: #{Exception.message(exception)}")
    end
  end

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
  defp relay(conn, %Req.Response{body: %Req.Response.Async{ref: ref}} = resp) do
    receive do
      {^ref, _} = message ->
        case Req.parse_message(resp, message) do
          {:ok, chunks} ->
            relay_chunks(conn, resp, chunks)

          {:error, reason} ->
            Logger.warning("ai gateway: upstream stream error: #{inspect(reason)}")
            conn
        end
    after
      @receive_timeout ->
        Logger.warning("ai gateway: upstream stream idle for #{@receive_timeout}ms; closing")
        Req.cancel_async_response(resp)
        conn
    end
  end

  # A message may carry several chunks; keep receiving until :done or the
  # client goes away.
  defp relay_chunks(conn, resp, []), do: relay(conn, resp)

  defp relay_chunks(conn, resp, [{:data, data} | rest]) do
    case Plug.Conn.chunk(conn, data) do
      {:ok, conn} ->
        relay_chunks(conn, resp, rest)

      {:error, _closed} ->
        Req.cancel_async_response(resp)
        conn
    end
  end

  defp relay_chunks(conn, _resp, [:done | _]), do: conn
  defp relay_chunks(conn, resp, [{:trailers, _} | rest]), do: relay_chunks(conn, resp, rest)

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
