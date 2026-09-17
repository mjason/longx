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

  # a rate limit or a wobbly upstream: three waits, long enough for a limit window to pass
  @default_retry_ms [5_000, 15_000, 30_000]

  @typedoc "A request resolved and prepared (`prepare/1`) — one entry per model of the chain — or why it could not be."
  @type prepared ::
          {:ok, [%{up: map, target: AI.Target.t(), request: map}]} | {:error, String.t()}

  @doc """
  Resolves the model and prepares the request — the part that reads the
  database. It runs in the kernel's own process, never in the task: a task
  killed mid-query (an interrupt, a parent stopping) took SQLite's
  connection down with it and the next write anywhere said "Database busy".
  """
  @spec prepare(map) :: prepared
  def prepare(request) when is_map(request) do
    with {:ok, targets} <- AI.resolve_targets(request["model"]),
         {:ok, entries} <- prepare_each(targets, request) do
      {:ok, entries}
    else
      {:error, reason} ->
        Log.begin(request, nil) |> Log.finish(%{status: nil, error: describe(reason)})
        {:error, describe(reason)}
    end
  end

  defp prepare_each(targets, request) do
    Enum.reduce_while(targets, {:ok, []}, fn target, {:ok, acc} ->
      case request |> custom_tools(target) |> Gateway.prepare(target) do
        {:ok, up} -> {:cont, {:ok, acc ++ [%{up: up, target: target, request: request}]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Streams a prepared request to `owner` (the task's body): the chain's first
  model, then — when it is refused for its quota, its key or an upstream
  that stays down — the next, telling the owner `{:fallback, from, to, why}`.
  A failed preparation is reported the same way as a failed call.
  """
  @spec run(prepared, pid, reference) :: :ok
  def run({:ok, [first | rest]}, owner, ref) when is_pid(owner) do
    Process.monitor(owner)
    run_chain(first, rest, owner, ref)
  end

  def run({:error, message}, owner, ref) when is_pid(owner), do: failed(owner, ref, message)

  defp run_chain(%{up: up, target: target, request: request}, rest, owner, ref) do
    log = Log.begin(request, %{upstream_id: target.model, provider: target.provider_slug})

    case attempt(up, target, owner, ref, log, retry_ms()) do
      :ok ->
        :ok

      {:failed, message} ->
        case rest do
          [] ->
            failed(owner, ref, message)

          [next | others] ->
            Logger.warning("agent model: #{message}; falling back to #{next.target.model}")
            send(owner, {:model, ref, {:fallback, target.model, next.target.model, message}})
            run_chain(next, others, owner, ref)
        end
    end
  end

  @doc "`prepare/1` then `run/3`, in the calling process (tests, scripts)."
  @spec stream(map, pid, reference) :: :ok
  def stream(request, owner, ref) when is_map(request) and is_pid(owner),
    do: request |> prepare() |> run(owner, ref)

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

  # one model: `:ok` when its stream ended (well or with the provider's own
  # failure relayed), `{:failed, message}` when the call never got going —
  # what the chain's next model may pick up
  defp attempt(up, target, owner, ref, log, retries) do
    outcome =
      Limiter.run(up.provider_slug, up.max_concurrent, fn -> post(up, target, owner, ref) end)

    case {outcome, retries} do
      {{:ok, {:done, status}}, _} ->
        Log.finish(log, %{status: status, error: nil})
        :ok

      {{:ok, {:retry, _status, message}}, [wait | rest]} ->
        Logger.info("agent model: #{message}; retrying in #{wait} ms")
        Process.sleep(wait)
        attempt(up, target, owner, ref, log, rest)

      {{:ok, {_retry_or_failed, status, message}}, _} ->
        message = "#{target.model} (#{target.provider_slug}): #{message}"
        Log.finish(log, %{status: status, error: message})
        {:failed, message}

      {:busy, [wait | rest]} ->
        Process.sleep(wait)
        attempt(up, target, owner, ref, log, rest)

      {:busy, []} ->
        message = "provider #{up.provider_slug} is at its concurrency limit"
        Log.finish(log, %{status: 429, error: message})
        {:failed, message}
    end
  end

  # a 429 that is not a rate limit but a quota gone, an unpaid bill: no retry saves it
  @quota ~r/quota|exhaust|insufficient|balance|credit|billing|payment|exceeded your/i
  defp quota?(message), do: Regex.match?(@quota, message)

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

        cond do
          status == 429 and quota?(message) -> {:failed, status, message}
          status == 429 or status >= 500 -> {:retry, status, message}
          true -> {:failed, status, message}
        end

      {:error, %Req.TransportError{} = e} ->
        {:retry, nil, "upstream unreachable: #{Exception.message(e)}"}

      {:error, e} ->
        {:failed, nil, "request failed: #{Exception.message(e)}"}
    end
  end

  # the event loop: chunks parsed as SSE, each event relayed; ends with the
  # stream, a completion, a failure, silence past the timeout or the owner's death
  # only this response's messages (`{req_ref, …}`) and the owner's death: a
  # catch-all would eat unrelated messages — the events we send to the owner
  # itself when it is this very process (tests), for one
  defp relay(
         %Req.Response{body: %Req.Response.Async{ref: req_ref}} = resp,
         target,
         owner,
         ref,
         buffer,
         completed?,
         timeout
       ) do
    receive do
      {:DOWN, _ref, :process, ^owner, _reason} ->
        exit(:normal)

      {^req_ref, _} = message ->
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

          {:error, reason} ->
            {:failed, 200, "the stream broke: #{inspect(reason)}"}

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
  defp collect(%Req.Response{body: %Req.Response.Async{ref: req_ref}} = resp, acc \\ "") do
    receive do
      {^req_ref, _} = message ->
        case Req.parse_message(resp, message) do
          {:ok, chunks} ->
            data = for {:data, d} <- chunks, into: "", do: d
            if :done in chunks, do: acc <> data, else: collect(resp, acc <> data)

          _other ->
            acc
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
