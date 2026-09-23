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

  # the provider is drawing (hosted image generation): a row in progress
  def fold(state, {:item_added, %{"id" => id, "type" => "image_generation_call"} = item}) do
    ui = UI.image_generation_ui(new_id("item"), state.turn_id, item, "inProgress")
    emit(state, "item/started", %{"item" => ui, "turnId" => state.turn_id})
    put_item(state, id, %{ui: ui["id"], kind: :hosted_call})
  end

  # a call opened: the model is writing its arguments now — shown as
  # progress (name, bytes so far) until the call runs, since nothing else
  # reaches the thread while a long patch streams
  def fold(state, {:item_added, %{"id" => id, "type" => type} = item})
      when type in ["function_call", "custom_tool_call"] do
    name = item["name"] || "tool"
    progress = %{item: id, name: name, bytes: 0, shown_at: System.monotonic_time(:millisecond)}
    show_progress(%{state | progress: progress})
  end

  def fold(state, {:item_added, _item}), do: state

  def fold(%State{progress: %{item: id} = progress} = state, {:arguments_delta, id, delta}) do
    progress = %{progress | bytes: progress.bytes + byte_size(delta)}
    now = System.monotonic_time(:millisecond)

    # the first bytes at once, then at most one event a second: a hint, not a stream
    if progress.bytes == byte_size(delta) or now - progress.shown_at >= 1_000,
      do: show_progress(%{state | progress: %{progress | shown_at: now}}),
      else: %{state | progress: progress}
  end

  def fold(state, {:arguments_delta, _id, _delta}), do: state

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

  # the picture came: saved as an attachment of the project, shown inline; the
  # model's context gets a note naming the file — never the bytes (with `store:
  # false` every step replays the history, and one image is a megabyte or two)
  def fold(state, {:item_done, %{"type" => "image_generation_call", "id" => id} = item}) do
    ui_id = ui_id(state, id)

    case save_image(state, item) do
      {:ok, details} ->
        ui = UI.image_generation_ui(ui_id, state.turn_id, item, "completed", details)

        note =
          "[image_generation] The image you generated (#{item["revised_prompt"] || "no prompt"}) " <>
            "was saved as the attachment #{details["path"]} (#{details["bytes"]} bytes, #{details["mime"]}) " <>
            "and shown to the person. Refer to it by that name; view_image its path to look at it."

        state
        |> append(:hosted_call, State.user_input(note, []), ui)
        |> drop_item(id)

      {:error, reason} ->
        ui = UI.image_generation_ui(ui_id, state.turn_id, item, "failed")

        note = "[image_generation] The image could not be saved: #{inspect(reason)}"

        state
        |> append(:hosted_call, State.user_input(note, []), ui)
        |> drop_item(id)
    end
  end

  def fold(state, {:item_done, %{"type" => "web_search_call", "id" => id} = item}) do
    ui = UI.hosted_search_ui(ui_id(state, id), state.turn_id, item, "completed")
    %{(state |> append(:hosted_call, item, ui) |> drop_item(id)) | last_search: ui}
  end

  def fold(state, {:item_done, %{"type" => type} = item})
      when type in ["function_call", "custom_tool_call"] do
    state = %{state | calls: state.calls ++ [item]}
    # the call is whole: the progress it was is over (it shows as a call next)
    if state.progress, do: show_progress(%{state | progress: nil}), else: state
  end

  def fold(state, {:item_done, _item}), do: state

  # the upstream's silence past the threshold (`Longx.Agent.Model`): on the call's
  # progress when one is being written, else a waiting of its own naming the model;
  # nil when data comes again. A backend once stopped mid-call with its connection
  # open and the page said 正在写 apply_patch 的参数 for ten minutes, as if Longx hung
  def fold(state, {:quiet, ms}), do: show_progress(%{state | quiet: ms})

  @doc """
  Tells the thread what the model is writing (`turn/progress`), that it is
  waiting on an upstream that has sent nothing for `quiet` seconds, or that
  nothing is (nil).
  """
  def show_progress(%State{progress: nil, quiet: nil} = state) do
    emit(state, "turn/progress", %{"turnId" => state.turn_id, "progress" => nil})
    state
  end

  def show_progress(%State{progress: nil, quiet: ms} = state) do
    model = (state.turn_model && state.turn_model[:slug]) || "the model"

    emit(state, "turn/progress", %{
      "turnId" => state.turn_id,
      "progress" => %{
        "kind" => "waiting",
        "name" => model,
        "bytes" => 0,
        "quiet" => div(ms, 1000)
      }
    })

    state
  end

  def show_progress(%State{progress: %{name: name, bytes: bytes}} = state) do
    emit(state, "turn/progress", %{
      "turnId" => state.turn_id,
      "progress" =>
        with_quiet(%{"kind" => "toolCall", "name" => name, "bytes" => bytes}, state.quiet)
    })

    state
  end

  @doc "A progress map with the upstream's silence (seconds) when there is one."
  def with_quiet(progress, nil), do: progress
  def with_quiet(progress, ms), do: Map.put(progress, "quiet", div(ms, 1000))

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

  @doc """
  The stream broke and the model is asked again: what it had said so far is
  closed in the view as it stands (the person saw it) but not given to the
  model — the next stream says it whole — and the calls collected so far go.
  """
  def discard_open_items(%State{items: items} = state) do
    state =
      Enum.reduce(items, state, fn
        {id, %{kind: :message, text: text, ui: ui_id}}, acc ->
          ui = %{"id" => ui_id, "type" => "agentMessage", "turnId" => acc.turn_id, "text" => text}
          emit(acc, "item/completed", %{"item" => ui, "turnId" => acc.turn_id})
          drop_item(acc, id)

        {id, %{kind: :reasoning, ui: ui_id, summary: summary, content: content}}, acc ->
          ui = %{
            "id" => ui_id,
            "type" => "reasoning",
            "turnId" => acc.turn_id,
            "summary" => ordered(summary),
            "content" => ordered(content)
          }

          emit(acc, "item/completed", %{"item" => ui, "turnId" => acc.turn_id})
          drop_item(acc, id)

        {id, _other}, acc ->
          drop_item(acc, id)
      end)

    %{state | calls: [], progress: nil, quiet: nil}
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

  ## Hosted image generation: the bytes to a file

  defp save_image(%State{project_id: project_id, thread_id: thread_id}, item) do
    with {:ok, bytes} <- decode_image(item["result"]) do
      format =
        if item["output_format"] in ["png", "jpeg", "webp"],
          do: item["output_format"],
          else: "png"

      ext = if format == "jpeg", do: "jpg", else: format

      name =
        "image-#{String.slice(thread_id, -6, 6)}-#{System.unique_integer([:positive])}.#{ext}"

      with {:ok, %{path: _path, name: saved, bytes: size}} <-
             Longx.Projects.Attachments.store_bytes(project_id || "adhoc", name, bytes) do
        {:ok,
         %{
           "path" => saved,
           "name" => saved,
           "bytes" => size,
           "mime" => "image/#{format}",
           "attachment" => true,
           "title" => item["revised_prompt"]
         }}
      end
    end
  end

  defp decode_image(result) when is_binary(result) and result != "" do
    case Base.decode64(result) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :not_base64}
    end
  end

  defp decode_image(_), do: {:error, :no_image}
end
