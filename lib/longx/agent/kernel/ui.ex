defmodule Longx.Agent.Kernel.UI do
  @moduledoc false
  # The items the person sees: a tool call as it starts and ends, a hosted search row, the citations of a message.

  alias Longx.Agent.Tool
  alias Longx.Agent.Kernel.State
  import Longx.Agent.Kernel.State

  # the sources a hosted search found arrive as the message's url_citation
  # annotations: they become the results of the last search row of the step
  def cite(%State{last_search: %{} = search} = state, %{"content" => content})
      when is_list(content) do
    results =
      for %{"annotations" => annotations} <- content,
          %{"type" => "url_citation", "url" => url} = a <- List.wrap(annotations),
          uniq: true,
          do: %{"title" => a["title"] || url, "url" => url}

    if results == [] do
      state
    else
      ui =
        Map.put(
          search,
          "results",
          Enum.uniq_by(List.wrap(search["results"]) ++ results, & &1["url"])
        )

      emit(state, "item/completed", %{"item" => ui, "turnId" => state.turn_id})
      %{state | last_search: nil}
    end
  end

  def cite(state, _item), do: state

  def hosted_search_ui(id, turn_id, %{"action" => action} = item, status) when is_map(action) do
    camel =
      case action["type"] do
        "open_page" -> "openPage"
        "find_in_page" -> "findInPage"
        other -> other || "search"
      end

    # 百炼 sends several queries per call and the sources on the action
    # (`{type: "url", url}`); OpenAI one query and the sources as the
    # message's url_citation annotations (`cite/2`)
    queries = action["queries"] |> List.wrap() |> Enum.reject(&(&1 in [nil, ""]))

    query =
      case queries do
        [] -> action["query"] || action["url"] || action["pattern"] || ""
        many -> Enum.join(many, " · ")
      end

    results =
      for %{"url" => url} = source <- List.wrap(action["sources"]),
          is_binary(url),
          do: %{"title" => source["title"] || url, "url" => url}

    %{
      "id" => id,
      "type" => "webSearch",
      "turnId" => turn_id,
      "query" => query,
      "action" => action |> Map.put("type", camel) |> Map.delete("sources"),
      "status" => item["status"] || status,
      "results" => results
    }
  end

  def hosted_search_ui(id, turn_id, item, status),
    do: hosted_search_ui(id, turn_id, Map.put(item, "action", %{"type" => "search"}), status)

  ## UI items

  def started_ui(%Tool{show: :command}, name, id, args, state) do
    # codex's `cmd`; a plug's own command-like tool shows its name and arguments
    command =
      case arg(args, "cmd") do
        "" -> name <> " " <> Jason.encode!(if(is_map(args), do: args, else: %{}))
        cmd -> cmd
      end

    %{
      "id" => id,
      "type" => "commandExecution",
      "turnId" => state.turn_id,
      "command" => command,
      "cwd" => state.cwd,
      "status" => "inProgress",
      "aggregatedOutput" => ""
    }
  end

  def started_ui(%Tool{show: :file_change}, _name, id, args, state) do
    %{
      "id" => id,
      "type" => "fileChange",
      "turnId" => state.turn_id,
      "changes" => changes_from(args, state.cwd),
      "status" => "inProgress"
    }
  end

  def started_ui(%Tool{show: :web_search}, name, id, args, state) do
    open? = name == "web_fetch" or (is_map(args) and is_binary(args["url"]))

    %{
      "id" => id,
      "type" => "webSearch",
      "turnId" => state.turn_id,
      "query" => arg(args, if(open?, do: "url", else: "query")),
      "action" =>
        if(open?,
          do: %{"type" => "openPage", "url" => arg(args, "url")},
          else: %{"type" => "search", "query" => arg(args, "query")}
        ),
      "status" => "inProgress"
    }
  end

  def started_ui(tool, name, id, args, state) do
    %{
      "id" => id,
      "type" => "dynamicToolCall",
      "turnId" => state.turn_id,
      "namespace" => (tool && tool.namespace) || "tool",
      "tool" => name,
      "arguments" => if(is_map(args), do: args, else: %{}),
      "status" => "inProgress"
    }
  end

  def completed_ui(%Tool{show: :command}, id, turn_id, ok?, text, streamed, duration, extra) do
    exit_code = Map.get(extra, "exitCode", if(ok?, do: 0, else: nil))
    output = if(ok?, do: streamed, else: streamed <> "\n" <> text)

    %{
      "id" => id,
      "type" => "commandExecution",
      "turnId" => turn_id,
      "status" => if(ok?, do: "completed", else: "failed"),
      "exitCode" => exit_code,
      "aggregatedOutput" => output,
      "durationMs" => Map.get(extra, "durationMs", duration)
    }
    |> Map.merge(Map.take(extra, ["command", "cwd"]))
  end

  def completed_ui(
        %Tool{show: :file_change},
        id,
        turn_id,
        ok?,
        text,
        _streamed,
        _duration,
        extra
      ) do
    %{
      "id" => id,
      "type" => "fileChange",
      "turnId" => turn_id,
      "status" => if(ok?, do: "completed", else: "failed"),
      "output" => text
    }
    |> Map.merge(Map.take(extra, ["changes"]))
  end

  def completed_ui(
        %Tool{show: :web_search},
        id,
        turn_id,
        ok?,
        _text,
        _streamed,
        _duration,
        extra
      ) do
    %{
      "id" => id,
      "type" => "webSearch",
      "turnId" => turn_id,
      "status" => if(ok?, do: "completed", else: "failed"),
      "results" => List.wrap(extra["results"])
    }
  end

  def completed_ui(%Tool{} = tool, id, turn_id, ok?, text, _streamed, duration, _extra) do
    %{
      "id" => id,
      "type" => "dynamicToolCall",
      "turnId" => turn_id,
      "namespace" => tool.namespace,
      "tool" => tool.name,
      "status" => if(ok?, do: "completed", else: "failed"),
      "success" => ok?,
      "contentItems" => [%{"type" => "inputText", "text" => text}],
      "durationMs" => duration
    }
  end

  @doc "A `longx.present` item already complete: a card pushed by a plug (`Context.present/2`)."
  def present_ui(id, turn_id, tree) do
    %{
      "id" => id,
      "type" => "dynamicToolCall",
      "turnId" => turn_id,
      "namespace" => "longx",
      "tool" => "present",
      "arguments" => tree,
      "status" => "completed",
      "success" => true,
      "contentItems" => [],
      "durationMs" => 0
    }
  end

  def delta_method(:command), do: "item/commandExecution/outputDelta"
  def delta_method(:file_change), do: "item/fileChange/outputDelta"
  def delta_method(_), do: "item/dynamicToolCall/outputDelta"

  # what a file change will touch, known before it runs: the patch's headers
  # (apply_patch) or the one path a tool names
  def changes_from(%{"input" => patch}, cwd) when is_binary(patch) do
    case Longx.Agent.Tools.Patch.parse(patch) do
      {:ok, hunks} ->
        Enum.map(hunks, fn
          {:add, path, _} ->
            %{"path" => Path.expand(path, cwd), "kind" => "add"}

          {:delete, path} ->
            %{"path" => Path.expand(path, cwd), "kind" => "delete"}

          {:update, path, move, _} ->
            %{"path" => Path.expand(move || path, cwd), "kind" => "update"}
        end)

      {:error, _} ->
        []
    end
  end

  def changes_from(%{"path" => path}, cwd) when is_binary(path),
    do: [%{"path" => Path.expand(path, cwd), "kind" => "update"}]

  def changes_from(_args, _cwd), do: []

  def arg(args, key) when is_map(args), do: to_string(Map.get(args, key, ""))
  def arg(_args, _key), do: ""
end
