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

    events
    |> Enum.with_index()
    |> Enum.map(fn {event, seq} ->
      event = Map.put(event, :sequence_number, seq)
      "event: #{event.type}\ndata: #{Jason.encode!(event)}\n\n"
    end)
  end
end
