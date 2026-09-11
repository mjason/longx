defmodule Longx.Test.ResponsesFixture do
  @moduledoc """
  A minimal but well-formed Responses API SSE stream: one assistant message.
  Shapes follow OpenAI's streaming events so codex accepts them.
  """

  @spec assistant_message(String.t(), keyword) :: [String.t()]
  def assistant_message(text, opts \\ []) do
    model = Keyword.get(opts, :model, "fake-model")
    item_id = "msg_" <> Integer.to_string(System.unique_integer([:positive]))
    resp_id = "resp_" <> Integer.to_string(System.unique_integer([:positive]))

    item_done = %{
      id: item_id,
      type: "message",
      status: "completed",
      role: "assistant",
      content: [%{type: "output_text", text: text, annotations: []}]
    }

    response = %{id: resp_id, object: "response", created_at: 1, model: model, output: []}

    events = [
      %{type: "response.created", response: Map.put(response, :status, "in_progress")},
      %{type: "response.in_progress", response: Map.put(response, :status, "in_progress")},
      %{
        type: "response.output_item.added",
        output_index: 0,
        item: %{
          id: item_id,
          type: "message",
          status: "in_progress",
          role: "assistant",
          content: []
        }
      },
      %{
        type: "response.content_part.added",
        item_id: item_id,
        output_index: 0,
        content_index: 0,
        part: %{type: "output_text", text: "", annotations: []}
      },
      %{
        type: "response.output_text.delta",
        item_id: item_id,
        output_index: 0,
        content_index: 0,
        delta: text
      },
      %{
        type: "response.output_text.done",
        item_id: item_id,
        output_index: 0,
        content_index: 0,
        text: text
      },
      %{
        type: "response.content_part.done",
        item_id: item_id,
        output_index: 0,
        content_index: 0,
        part: %{type: "output_text", text: text, annotations: []}
      },
      %{type: "response.output_item.done", output_index: 0, item: item_done},
      %{
        type: "response.completed",
        response:
          Map.merge(response, %{
            status: "completed",
            output: [item_done],
            usage: %{
              input_tokens: 12,
              input_tokens_details: %{cached_tokens: 0},
              output_tokens: 5,
              output_tokens_details: %{reasoning_tokens: 0},
              total_tokens: 17
            }
          })
      }
    ]

    to_sse(events)
  end

  @doc """
  A stream whose only output is one function call. `namespace` is set for
  namespaced tools (e.g. `web` / `run`), exactly as DeepSeek returns them.
  """
  @spec function_call(String.t(), String.t() | nil, map, keyword) :: [String.t()]
  def function_call(name, namespace, arguments, opts \\ []) do
    model = Keyword.get(opts, :model, "fake-model")
    call_id = "call_" <> Integer.to_string(System.unique_integer([:positive]))
    item_id = "fc_" <> Integer.to_string(System.unique_integer([:positive]))
    resp_id = "resp_" <> Integer.to_string(System.unique_integer([:positive]))
    args = Jason.encode!(arguments)

    base = %{id: item_id, type: "function_call", call_id: call_id, name: name}
    base = if namespace, do: Map.put(base, :namespace, namespace), else: base
    item_done = Map.merge(base, %{status: "completed", arguments: args})
    response = %{id: resp_id, object: "response", created_at: 1, model: model, output: []}

    to_sse([
      %{type: "response.created", response: Map.put(response, :status, "in_progress")},
      %{
        type: "response.output_item.added",
        output_index: 0,
        item: Map.merge(base, %{status: "in_progress", arguments: ""})
      },
      %{
        type: "response.function_call_arguments.delta",
        item_id: item_id,
        output_index: 0,
        delta: args
      },
      %{
        type: "response.function_call_arguments.done",
        item_id: item_id,
        output_index: 0,
        arguments: args
      },
      %{type: "response.output_item.done", output_index: 0, item: item_done},
      %{
        type: "response.completed",
        response:
          Map.merge(response, %{
            status: "completed",
            output: [item_done],
            usage: %{input_tokens: 10, output_tokens: 5, total_tokens: 15}
          })
      }
    ])
  end

  defp to_sse(events) do
    events
    |> Enum.with_index()
    |> Enum.map(fn {event, seq} ->
      event = Map.put(event, :sequence_number, seq)
      "event: #{event.type}\ndata: #{Jason.encode!(event)}\n\n"
    end)
  end
end
