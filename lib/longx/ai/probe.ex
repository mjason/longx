defmodule Longx.AI.Probe do
  @moduledoc "A bounded health check using the same request adapter as conversations."
  alias Longx.AI.{Gateway, Target}
  alias Longx.Agent.Model.SSE

  @timeout 30_000
  @max_bytes 512_000

  def run(%Target{} = target, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @timeout)
    max_bytes = Keyword.get(opts, :max_bytes, @max_bytes)
    finch = Keyword.get(opts, :finch, Longx.AI.Finch)
    started = System.monotonic_time(:millisecond)
    # No hosted tools, and the cheapest declared reasoning level. Omit the
    # optional output cap for Codex; bound that check by time and bytes.
    effort = Enum.find(["none", "minimal", "low"], &(&1 in target.levels))

    target = %{
      target
      | max_output_tokens: if(target.chatgpt?, do: nil, else: 1024),
        image_generation?: false
    }

    body = %{
      "instructions" => "",
      "input" => [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [%{"type" => "input_text", "text" => "Reply with the single word: ok"}]
        }
      ],
      "store" => false,
      "tools" => []
    }

    body = if effort, do: Map.put(body, "reasoning", %{"effort" => effort}), else: body

    with {:ok, up} <- Gateway.prepare(body, target) do
      task =
        Task.Supervisor.async_nolink(Longx.Agent.TaskSupervisor, fn ->
          request(up, timeout, max_bytes, finch)
        end)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, :ok} -> {:ok, %{latency_ms: System.monotonic_time(:millisecond) - started}}
        {:ok, {:error, _} = error} -> error
        {:exit, _} -> {:error, {:unreachable, "the model check connection failed"}}
        nil -> {:error, {:unreachable, "the model check timed out after #{timeout}ms"}}
      end
    end
  end

  defp request(up, timeout, max_bytes, finch) do
    req = Finch.build(:post, up.url, up.headers, Jason.encode!(up.body))
    state = %{status: nil, json?: false, buffer: "", bytes: 0, result: nil}

    case Finch.stream_while(req, finch, state, &chunk(&1, &2, max_bytes),
           pool_timeout: min(timeout, 5000),
           receive_timeout: timeout,
           request_timeout: timeout
         ) do
      {:ok, state} -> finish(state)
      {:error, exception, _state} -> {:error, {:unreachable, Exception.message(exception)}}
    end
  end

  defp chunk({:status, status}, state, _max), do: {:cont, %{state | status: status}}

  defp chunk({:headers, headers}, state, _max) do
    json? =
      Enum.any?(headers, fn {k, v} ->
        String.downcase(k) == "content-type" and
          String.contains?(String.downcase(v), "application/json")
      end)

    {:cont, %{state | json?: json?}}
  end

  defp chunk({:data, data}, state, max) do
    bytes = state.bytes + byte_size(data)

    cond do
      bytes > max ->
        {:halt,
         %{state | result: failure(state.status, "model check response exceeded #{max} bytes")}}

      state.status not in 200..299 or state.json? ->
        {:cont, %{state | buffer: state.buffer <> data, bytes: bytes}}

      true ->
        {events, rest} = SSE.parse(state.buffer, data)
        result = Enum.find_value(events, &terminal/1)
        state = %{state | buffer: rest, bytes: bytes, result: result}
        if result, do: {:halt, state}, else: {:cont, state}
    end
  end

  defp chunk(_event, state, _max), do: {:cont, state}

  defp terminal({"response.completed", %{"response" => %{} = response}}), do: completed(response)

  defp terminal({"response.failed", payload}),
    do: {:failed, message(payload["response"] || payload)}

  defp terminal({"response.incomplete", _}), do: {:failed, "upstream response was incomplete"}
  defp terminal({"error", payload}), do: {:failed, message(payload)}
  defp terminal(_), do: nil

  defp completed(%{"status" => "completed"}), do: :ok
  defp completed(response), do: {:failed, message(response)}

  defp finish(%{result: :ok}), do: :ok
  defp finish(%{result: {:error, _} = error}), do: error
  defp finish(%{status: status, result: {:failed, why}}), do: failure(status, why)

  defp finish(%{status: status, buffer: body}) when status not in 200..299,
    do: failure(status, decode_message(body))

  defp finish(%{json?: true, status: status, buffer: body}) do
    case Jason.decode(body) do
      {:ok, %{"status" => "completed"}} -> :ok
      {:ok, response} -> failure(status, message(response))
      _ -> failure(status, "upstream returned invalid JSON")
    end
  end

  defp finish(%{status: status}),
    do: failure(status, "upstream stream ended without a completed response")

  defp failure(status, message), do: {:error, {:status, status || 502, message}}

  defp decode_message(body) do
    case Jason.decode(body) do
      {:ok, value} -> message(value)
      _ -> String.slice(body, 0, 500)
    end
  end

  defp message(%{"error" => %{"message" => message}}) when is_binary(message), do: message
  defp message(%{"detail" => message}) when is_binary(message), do: message
  defp message(%{"message" => message}) when is_binary(message), do: message
  defp message(_), do: "upstream did not complete the model check"
end
