defmodule Longx.Agent.Model do
  @moduledoc """
  One streamed Responses API call, as messages to the agent process. Runs
  inside a task: `stream/3` resolves the model (`Longx.AI.resolve_target/1`
  — `longx` is the default model), prepares the request the way the
  gateway does for codex (`Longx.AI.Gateway.prepare/2`: reasoning items
  sanitised per provider, the output cap), holds a limiter slot, records
  the request in `Longx.AI.Gateway.Log`, and relays the stream as
  `{:model, ref, event}`:

    * `{:item_added, item}` — an output item began (message, reasoning, function_call)
    * `{:text_delta, item_id, text}` / `{:reasoning_delta, item_id, index, text}`
      / `{:reasoning_text_delta, item_id, index, text}`
    * `{:item_done, item}` — the whole item
    * `{:completed, response, %{context_window: n}}` — the end, usage inside
    * `{:failed, message}` — nothing more is coming

  A 429 / 5xx / transport error before anything streamed is retried
  (`config :longx, Longx.Agent.Model, retry_ms:`); a 4xx is final. The
  task ends when its owner does.
  """

  require Logger

  alias Longx.Agent.SSE
  alias Longx.AI
  alias Longx.AI.Gateway
  alias Longx.AI.Gateway.{Limiter, Log}

  @default_retry_ms [1_000, 2_000, 4_000]

  @spec stream(map, pid, reference) :: :ok
  def stream(request, owner, ref) when is_map(request) and is_pid(owner) do
    with {:ok, target} <- AI.resolve_target(request["model"]),
         {:ok, up} <- request |> custom_tools(target) |> Gateway.prepare(target) do
      log = Log.begin(request, %{upstream_id: target.model, provider: target.provider_slug})
      Process.monitor(owner)
      attempt(up, target, owner, ref, log, retry_ms())
    else
      {:error, reason} ->
        Log.begin(request, nil) |> Log.finish(%{status: nil, error: describe(reason)})
        failed(owner, ref, describe(reason))
    end
  end

  # a tool with a grammar goes out as a `custom` tool where the provider runs
  # them (OpenAI's Responses API); everyone else keeps the function form
  defp custom_tools(request, %{kind: :openai}) do
    {customs, request} = Map.pop(request, "x-longx-custom-tools", [])
    names = MapSet.new(customs, & &1["name"])

    Map.update(request, "tools", [], fn tools ->
      Enum.reject(tools, &MapSet.member?(names, &1["name"])) ++ customs
    end)
  end

  defp custom_tools(request, _target), do: Map.delete(request, "x-longx-custom-tools")

  defp retry_ms,
    do: :longx |> Application.get_env(__MODULE__, []) |> Keyword.get(:retry_ms, @default_retry_ms)

  defp attempt(up, target, owner, ref, log, retries) do
    outcome =
      Limiter.run(up.provider_slug, up.max_concurrent, fn -> post(up, target, owner, ref) end)

    case {outcome, retries} do
      {{:ok, {:done, status}}, _} ->
        Log.finish(log, %{status: status, error: nil})

      {{:ok, {:retry, _status, message}}, [wait | rest]} ->
        Logger.info("agent model: #{message}; retrying in #{wait} ms")
        Process.sleep(wait)
        attempt(up, target, owner, ref, log, rest)

      {{:ok, {_retry_or_failed, status, message}}, _} ->
        Log.finish(log, %{status: status, error: message})
        failed(owner, ref, message)

      {:busy, [wait | rest]} ->
        Process.sleep(wait)
        attempt(up, target, owner, ref, log, rest)

      {:busy, []} ->
        message = "provider #{up.provider_slug} is at its concurrency limit"
        Log.finish(log, %{status: 429, error: message})
        failed(owner, ref, message)
    end
  end

  defp post(up, target, owner, ref) do
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
        relay(resp, target, owner, ref, "", false, up.receive_timeout)

      {:ok, %Req.Response{status: status} = resp} ->
        message = "upstream answered #{status}: #{resp |> collect() |> error_message()}"

        if status == 429 or status >= 500,
          do: {:retry, status, message},
          else: {:failed, status, message}

      {:error, %Req.TransportError{} = e} ->
        {:retry, nil, "upstream unreachable: #{Exception.message(e)}"}

      {:error, e} ->
        {:failed, nil, "request failed: #{Exception.message(e)}"}
    end
  end

  # the event loop: chunks parsed as SSE, each event relayed; ends with the
  # stream, a completion, a failure, silence past the timeout or the owner's death
  defp relay(resp, target, owner, ref, buffer, completed?, timeout) do
    receive do
      {:DOWN, _ref, :process, ^owner, _reason} ->
        exit(:normal)

      message ->
        case Req.parse_message(resp, message) do
          {:ok, chunks} ->
            Enum.reduce_while(chunks, {:cont, buffer, completed?}, fn
              {:data, data}, {:cont, buf, done?} ->
                {events, rest} = SSE.parse(buf, data)

                case dispatch(events, target, owner, ref, done?) do
                  {:ok, done?} -> {:cont, {:cont, rest, done?}}
                  {:failed, why} -> {:halt, {:failed, why}}
                end

              :done, {:cont, _buf, done?} ->
                {:halt, {:ended, done?}}

              _other, acc ->
                {:cont, acc}
            end)
            |> case do
              {:cont, rest, done?} -> relay(resp, target, owner, ref, rest, done?, timeout)
              {:ended, true} -> {:done, 200}
              {:ended, false} -> {:failed, 200, "the stream ended without a response"}
              {:failed, why} -> {:failed, 200, why}
            end

          :unknown ->
            relay(resp, target, owner, ref, buffer, completed?, timeout)
        end
    after
      timeout -> {:failed, 200, "upstream went silent for #{timeout} ms"}
    end
  end

  defp dispatch([], _target, _owner, _ref, done?), do: {:ok, done?}

  defp dispatch([{type, payload} | rest], target, owner, ref, done?) do
    case event(type, payload, target) do
      {:failed, why} ->
        {:failed, why}

      nil ->
        dispatch(rest, target, owner, ref, done?)

      event ->
        send(owner, {:model, ref, event})
        completed? = done? or match?({:completed, _, _}, event)
        dispatch(rest, target, owner, ref, completed?)
    end
  end

  defp event("response.output_item.added", %{"item" => item}, _t), do: {:item_added, item}

  defp event("response.output_text.delta", %{"item_id" => id, "delta" => d}, _t),
    do: {:text_delta, id, d}

  defp event("response.reasoning_summary_text.delta", %{"item_id" => id, "delta" => d} = p, _t),
    do: {:reasoning_delta, id, p["summary_index"] || 0, d}

  defp event("response.reasoning_text.delta", %{"item_id" => id, "delta" => d} = p, _t),
    do: {:reasoning_text_delta, id, p["content_index"] || 0, d}

  defp event("response.output_item.done", %{"item" => item}, _t), do: {:item_done, item}

  defp event(type, %{"response" => response}, target)
       when type in ["response.completed", "response.incomplete"],
       do: {:completed, response, %{context_window: target.context_window}}

  defp event("response.failed", %{"response" => response}, _t),
    do: {:failed, "the model failed: " <> error_message(response)}

  defp event("error", payload, _t), do: {:failed, "the model failed: " <> error_message(payload)}
  defp event(_type, _payload, _t), do: nil

  defp failed(owner, ref, message) do
    send(owner, {:model, ref, {:failed, message}})
    :ok
  end

  # the body of a non-200 answer (also streamed by `into: :self`)
  defp collect(resp, acc \\ "") do
    receive do
      message ->
        case Req.parse_message(resp, message) do
          {:ok, chunks} ->
            data = for {:data, d} <- chunks, into: "", do: d
            if :done in chunks, do: acc <> data, else: collect(resp, acc <> data)

          :unknown ->
            collect(resp, acc)
        end
    after
      5_000 -> acc
    end
  end

  defp error_message(%{"error" => %{"message" => m}}) when is_binary(m), do: m
  defp error_message(%{"message" => m}) when is_binary(m), do: m

  defp error_message(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> error_message(decoded)
      _ -> String.slice(body, 0, 500)
    end
  end

  defp error_message(other), do: other |> inspect() |> String.slice(0, 500)

  defp describe({:unknown_model, slug}), do: "unknown model #{slug}"
  defp describe(:no_default_model), do: "no default model is configured"
  defp describe({:missing_api_key, slug}), do: "provider #{slug} has no API key"
  defp describe(:invalid_request), do: "invalid request"
end
