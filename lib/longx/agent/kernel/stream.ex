defmodule Longx.Agent.Kernel.Stream do
  @moduledoc false
  # The model's stream folded into the state: an item opened shows at once,
  # a delta is shown as it comes, a closed item goes into the transcript,
  # a call is collected for the response phase; and, when the response
  # ends, what was left open and what it cost.

  alias Longx.Agent.Kernel.{Goal, State, UI}
  import Longx.Agent.Kernel.State

  def fold(state, {:item_added, %{"id" => id, "type" => type}})
      when type in ["message", "reasoning"] do
    ui_id = new_id("item")
    kind = if type == "message", do: :message, else: :reasoning

    ui =
      case kind do
        :message ->
          %{"id" => ui_id, "type" => "agentMessage", "turnId" => state.turn_id, "text" => ""}

        :reasoning ->
          %{
            "id" => ui_id,
            "type" => "reasoning",
            "turnId" => state.turn_id,
            "summary" => [],
            "content" => []
          }
      end

    emit(state, "item/started", %{"item" => ui, "turnId" => state.turn_id})
    put_item(state, id, %{ui: ui_id, kind: kind, text: "", summary: %{}, content: %{}})
  end

  # a call the provider runs on its side (hosted web search): a webSearch row
  def fold(state, {:item_added, %{"id" => id, "type" => "web_search_call"} = item}) do
    ui = UI.hosted_search_ui(new_id("item"), state.turn_id, item, "inProgress")
    emit(state, "item/started", %{"item" => ui, "turnId" => state.turn_id})
    put_item(%{state | last_search: ui}, id, %{ui: ui["id"], kind: :hosted_call})
  end

  def fold(state, {:item_added, _item}), do: state

  def fold(state, {:text_delta, id, delta}) do
    with %{ui: ui_id} = item <- state.items[id] do
      emit(state, "item/agentMessage/delta", %{
        "itemId" => ui_id,
        "delta" => delta,
        "turnId" => state.turn_id
      })

      put_item(state, id, %{item | text: item.text <> delta})
    else
      _ -> state
    end
  end

  def fold(state, {:reasoning_delta, id, index, delta}) do
    with %{ui: ui_id} = item <- state.items[id] do
      emit(state, "item/reasoning/summaryTextDelta", %{
        "itemId" => ui_id,
        "delta" => delta,
        "summaryIndex" => index,
        "turnId" => state.turn_id
      })

      put_item(state, id, %{
        item
        | summary: Map.update(item.summary, index, delta, &(&1 <> delta))
      })
    else
      _ -> state
    end
  end

  def fold(state, {:reasoning_text_delta, id, index, delta}) do
    with %{ui: ui_id} = item <- state.items[id] do
      emit(state, "item/reasoning/textDelta", %{
        "itemId" => ui_id,
        "delta" => delta,
        "contentIndex" => index,
        "turnId" => state.turn_id
      })

      put_item(state, id, %{
        item
        | content: Map.update(item.content, index, delta, &(&1 <> delta))
      })
    else
      _ -> state
    end
  end

  def fold(state, {:item_done, %{"type" => "message", "id" => id} = item}) do
    text = message_text(item)
    ui_id = ui_id(state, id)
    ui = %{"id" => ui_id, "type" => "agentMessage", "turnId" => state.turn_id, "text" => text}

    state
    |> UI.cite(item)
    |> append(:agent_message, item, ui)
    |> drop_item(id)
  end

  def fold(state, {:item_done, %{"type" => "reasoning", "id" => id} = item}) do
    ui = %{
      "id" => ui_id(state, id),
      "type" => "reasoning",
      "turnId" => state.turn_id,
      "summary" => texts(item["summary"]),
      "content" => texts(item["content"])
    }

    state |> append(:reasoning, item, ui) |> drop_item(id)
  end

  def fold(state, {:item_done, %{"type" => "web_search_call", "id" => id} = item}) do
    ui = UI.hosted_search_ui(ui_id(state, id), state.turn_id, item, "completed")
    %{(state |> append(:hosted_call, item, ui) |> drop_item(id)) | last_search: ui}
  end

  def fold(state, {:item_done, %{"type" => type} = item})
      when type in ["function_call", "custom_tool_call"],
      do: %{state | calls: state.calls ++ [item]}

  def fold(state, {:item_done, _item}), do: state

  ## The response is over

  # a streamed item the model never closed (a failure, an interrupt) is
  # kept as far as it got — the person saw it, the model should too
  def close_open_items(%State{items: items} = state) when map_size(items) == 0, do: state

  def close_open_items(%State{items: items} = state) do
    Enum.reduce(items, state, fn
      {id, %{kind: :message, text: text, ui: ui_id}}, acc ->
        input = %{
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => text}]
        }

        ui = %{"id" => ui_id, "type" => "agentMessage", "turnId" => acc.turn_id, "text" => text}
        acc |> append(:agent_message, input, ui) |> drop_item(id)

      {id, %{kind: :reasoning, ui: ui_id, summary: summary, content: content}}, acc ->
        ui = %{
          "id" => ui_id,
          "type" => "reasoning",
          "turnId" => acc.turn_id,
          "summary" => ordered(summary),
          "content" => ordered(content)
        }

        # nothing for the model: a partial reasoning item cannot be replayed
        emit(acc, "item/completed", %{"item" => ui, "turnId" => acc.turn_id})
        drop_item(acc, id)
    end)
  end

  def record_usage(state, nil, _window), do: state

  def record_usage(%State{usage_total: total} = state, usage, window) do
    last = %{
      "inputTokens" => usage["input_tokens"] || 0,
      "cachedInputTokens" => get_in(usage, ["input_tokens_details", "cached_tokens"]) || 0,
      "outputTokens" => usage["output_tokens"] || 0,
      "reasoningOutputTokens" =>
        get_in(usage, ["output_tokens_details", "reasoning_tokens"]) || 0,
      "totalTokens" => usage["total_tokens"] || 0
    }

    total = Map.merge(total, last, fn _k, a, b -> a + b end)

    emit(state, "thread/tokenUsage/updated", %{
      "tokenUsage" => %{"modelContextWindow" => window, "last" => last, "total" => total}
    })

    %{state | usage_total: total, usage_last: last, context_window: window}
    |> Goal.charge_goal(last["totalTokens"])
  end
end
