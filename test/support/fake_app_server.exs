# A scripted stand-in for `codex-app-server`, run with `elixir fake_app_server.exs`
# under Longx.Shim exactly like the real binary. Speaks newline-delimited
# JSON-RPC on stdio. Behaviour is chosen by the user text of `turn/start`:
#
#   "say <words>"      stream <words> as agentMessage deltas, complete the turn
#   "approve <cmd>"    ask the client to approve <cmd> (server → client request),
#                      then run or decline it depending on the answer
#   "stall"            emit 3 deltas, wait for a `fake/continue` notification,
#                      then finish
#   "slow <ms>"        sleep <ms> before answering turn/start
#   "error"            answer turn/start with a JSON-RPC error
#   "die"              exit immediately (simulates a crash)
#   "server-notify"    emit a notification without a threadId
#
# Requests before the initialize/initialized handshake get "Not initialized".

defmodule FakeAppServer do
  def main do
    # ids unique per server process (like codex's UUIDs): the ETS-backed
    # ThreadState store outlives tests, so two fakes must never share ids
    loop(%{initialized: false, next: 1, prefix: System.pid(), threads: %{}, pending: %{}})
  end

  defp loop(state) do
    case IO.binread(:stdio, :line) do
      :eof ->
        :ok

      {:error, _} ->
        :ok

      line ->
        state =
          case String.trim(line) do
            "" -> state
            json -> handle(JSON.decode!(json), state)
          end

        loop(state)
    end
  end

  ## dispatch

  defp handle(%{"id" => id, "result" => result}, %{pending: pending} = state) do
    case Map.pop(pending, id) do
      {nil, _} -> state
      {continuation, rest} -> continuation.(result, %{state | pending: rest})
    end
  end

  defp handle(%{"id" => id, "error" => _}, %{pending: pending} = state) do
    case Map.pop(pending, id) do
      {nil, _} -> state
      {continuation, rest} -> continuation.(:error, %{state | pending: rest})
    end
  end

  defp handle(%{"id" => id, "method" => "initialize"}, %{initialized: false} = state) do
    reply(id, %{"userAgent" => "fake/0", "codexHome" => "/nowhere", "platformFamily" => "unix"})
    %{state | initialized: :pending}
  end

  defp handle(%{"id" => id, "method" => "initialize"}, state) do
    error(id, -32600, "Already initialized")
    state
  end

  defp handle(%{"method" => "initialized"}, %{initialized: :pending} = state),
    do: %{state | initialized: true}

  defp handle(%{"id" => id, "method" => _}, %{initialized: init} = state) when init != true do
    error(id, -32002, "Not initialized")
    state
  end

  defp handle(%{"id" => id, "method" => "thread/start"}, state) do
    thread_id = "thr_#{state.prefix}_#{state.next}"
    thread = %{"id" => thread_id, "preview" => "", "sessionId" => thread_id}
    reply(id, %{"thread" => thread})
    notify("thread/started", %{"thread" => thread})
    %{state | next: state.next + 1, threads: Map.put(state.threads, thread_id, %{turns: []})}
  end

  defp handle(
         %{"id" => id, "method" => "thread/resume", "params" => %{"threadId" => thread_id}},
         state
       ) do
    thread = %{"id" => thread_id, "preview" => "", "sessionId" => thread_id}
    reply(id, %{"thread" => thread})
    notify("thread/started", %{"thread" => thread})
    %{state | threads: Map.put_new(state.threads, thread_id, %{turns: []})}
  end

  defp handle(
         %{"id" => id, "method" => "thread/read", "params" => %{"threadId" => thread_id}},
         state
       ) do
    turns = state.threads |> Map.get(thread_id, %{turns: []}) |> Map.get(:turns) |> Enum.reverse()
    reply(id, %{"thread" => %{"id" => thread_id, "turns" => turns}})
    state
  end

  defp handle(
         %{
           "id" => id,
           "method" => "turn/start",
           "params" => %{"threadId" => thread_id, "input" => input}
         },
         state
       ) do
    text = input |> List.first(%{}) |> Map.get("text", "")
    turn_id = "turn_#{state.prefix}_#{state.next}"
    state = %{state | next: state.next + 1}
    run_turn(text, id, thread_id, turn_id, state)
  end

  defp handle(
         %{
           "id" => id,
           "method" => "turn/interrupt",
           "params" => %{"threadId" => thread_id, "turnId" => turn_id}
         },
         state
       ) do
    reply(id, %{})

    notify("turn/completed", %{
      "threadId" => thread_id,
      "turn" => %{"id" => turn_id, "status" => "interrupted", "items" => []}
    })

    state
  end

  defp handle(%{"id" => id, "method" => method}, state) do
    error(id, -32601, "Method not found: #{method}")
    state
  end

  defp handle(%{"method" => "fake/continue"}, %{pending: pending} = state) do
    case Map.pop(pending, :continue) do
      {nil, _} -> state
      {continuation, rest} -> continuation.(:continue, %{state | pending: rest})
    end
  end

  defp handle(_other, state), do: state

  ## turn scripts

  defp run_turn("say " <> words, id, thread_id, turn_id, state) do
    start_turn(id, thread_id, turn_id, "say " <> words)
    stream_message(thread_id, turn_id, String.split(words, " "))
    finish_turn(thread_id, turn_id, "completed", state, "say " <> words, words)
  end

  defp run_turn("approve " <> cmd, id, thread_id, turn_id, state) do
    start_turn(id, thread_id, turn_id, "approve " <> cmd)
    request_id = "srv_#{state.next}"

    request(request_id, "item/commandExecution/requestApproval", %{
      "threadId" => thread_id,
      "turnId" => turn_id,
      "itemId" => "call_#{state.next}",
      "command" => cmd,
      "cwd" => "/",
      "reason" => "fake wants approval",
      "startedAtMs" => 0
    })

    continuation = fn
      %{"decision" => "accept"}, state ->
        item = %{
          "id" => "call_x",
          "type" => "commandExecution",
          "command" => cmd,
          "status" => "completed",
          "aggregatedOutput" => "ran #{cmd}\n",
          "exitCode" => 0
        }

        notify("item/started", %{
          "threadId" => thread_id,
          "turnId" => turn_id,
          "item" => Map.put(item, "status", "inProgress")
        })

        notify("item/completed", %{"threadId" => thread_id, "turnId" => turn_id, "item" => item})
        finish_turn(thread_id, turn_id, "completed", state, "approve " <> cmd, "ran")

      _other, state ->
        stream_message(thread_id, turn_id, ["declined"])
        finish_turn(thread_id, turn_id, "completed", state, "approve " <> cmd, "declined")
    end

    %{state | next: state.next + 1, pending: Map.put(state.pending, request_id, continuation)}
  end

  defp run_turn("call " <> rest, id, thread_id, turn_id, state) do
    start_turn(id, thread_id, turn_id, "call " <> rest)
    [qualified, json] = String.split(rest, " ", parts: 2)
    [namespace, tool] = String.split(qualified, ".", parts: 2)
    request_id = "srv_#{state.next}"

    request(request_id, "item/tool/call", %{
      "threadId" => thread_id,
      "turnId" => turn_id,
      "callId" => "call_#{state.next}",
      "namespace" => namespace,
      "tool" => tool,
      "arguments" => JSON.decode!(json)
    })

    continuation = fn
      %{"success" => success, "contentItems" => items}, state ->
        text = Enum.map_join(items, " ", &(&1["text"] || &1["imageUrl"]))
        stream_message(thread_id, turn_id, ["tool", "#{success}:", text])

        finish_turn(
          thread_id,
          turn_id,
          "completed",
          state,
          "call " <> rest,
          "tool #{success}: #{text}"
        )

      :error, state ->
        stream_message(thread_id, turn_id, ["tool", "rpc-error"])
        finish_turn(thread_id, turn_id, "completed", state, "call " <> rest, "tool rpc-error")
    end

    %{state | next: state.next + 1, pending: Map.put(state.pending, request_id, continuation)}
  end

  defp run_turn("stall", id, thread_id, turn_id, state) do
    start_turn(id, thread_id, turn_id, "stall")
    item_id = "msg_#{turn_id}"

    notify("item/started", %{
      "threadId" => thread_id,
      "turnId" => turn_id,
      "item" => %{"id" => item_id, "type" => "agentMessage", "text" => ""}
    })

    for d <- ["a", "b", "c"],
        do:
          notify("item/agentMessage/delta", %{
            "threadId" => thread_id,
            "turnId" => turn_id,
            "itemId" => item_id,
            "delta" => d
          })

    continuation = fn :continue, state ->
      notify("item/agentMessage/delta", %{
        "threadId" => thread_id,
        "turnId" => turn_id,
        "itemId" => item_id,
        "delta" => "d"
      })

      notify("item/completed", %{
        "threadId" => thread_id,
        "turnId" => turn_id,
        "item" => %{"id" => item_id, "type" => "agentMessage", "text" => "abcd"}
      })

      finish_turn(thread_id, turn_id, "completed", state, "stall", "abcd")
    end

    %{state | pending: Map.put(state.pending, :continue, continuation)}
  end

  defp run_turn("slow " <> ms, id, thread_id, turn_id, state) do
    Process.sleep(String.to_integer(ms))
    run_turn("say slow", id, thread_id, turn_id, state)
  end

  defp run_turn("error", id, _thread_id, _turn_id, state) do
    error(id, -32000, "fake turn error")
    state
  end

  defp run_turn("die", _id, _thread_id, _turn_id, _state), do: System.halt(1)

  defp run_turn("server-notify", id, thread_id, turn_id, state) do
    start_turn(id, thread_id, turn_id, "server-notify")
    notify("account/rateLimits/updated", %{"rateLimits" => %{"remaining" => 1}})
    finish_turn(thread_id, turn_id, "completed", state, "server-notify", "")
  end

  defp run_turn(other, id, thread_id, turn_id, state),
    do: run_turn("say " <> other, id, thread_id, turn_id, state)

  defp start_turn(id, thread_id, turn_id, text) do
    turn = %{"id" => turn_id, "status" => "inProgress", "items" => []}
    reply(id, %{"turn" => turn})
    notify("turn/started", %{"threadId" => thread_id, "turn" => turn})

    user = %{
      "id" => "user_#{turn_id}",
      "type" => "userMessage",
      "content" => [%{"type" => "text", "text" => text}]
    }

    notify("item/started", %{"threadId" => thread_id, "turnId" => turn_id, "item" => user})
    notify("item/completed", %{"threadId" => thread_id, "turnId" => turn_id, "item" => user})
  end

  defp stream_message(thread_id, turn_id, words) do
    item_id = "msg_#{turn_id}"

    notify("item/started", %{
      "threadId" => thread_id,
      "turnId" => turn_id,
      "item" => %{"id" => item_id, "type" => "agentMessage", "text" => ""}
    })

    words
    |> Enum.intersperse(" ")
    |> Enum.each(
      &notify("item/agentMessage/delta", %{
        "threadId" => thread_id,
        "turnId" => turn_id,
        "itemId" => item_id,
        "delta" => &1
      })
    )

    notify("item/completed", %{
      "threadId" => thread_id,
      "turnId" => turn_id,
      "item" => %{"id" => item_id, "type" => "agentMessage", "text" => Enum.join(words, " ")}
    })
  end

  defp finish_turn(thread_id, turn_id, status, state, user_text, agent_text) do
    turn = %{"id" => turn_id, "status" => status, "items" => []}

    notify("thread/tokenUsage/updated", %{
      "threadId" => thread_id,
      "turnId" => turn_id,
      "tokenUsage" => %{"total" => 7}
    })

    notify("turn/completed", %{"threadId" => thread_id, "turn" => turn})

    recorded = %{
      "id" => turn_id,
      "status" => status,
      "items" => [
        %{
          "id" => "user_#{turn_id}",
          "type" => "userMessage",
          "content" => [%{"type" => "text", "text" => user_text}]
        },
        %{"id" => "msg_#{turn_id}", "type" => "agentMessage", "text" => agent_text}
      ]
    }

    update_in(state, [:threads, thread_id, :turns], &[recorded | &1 || []])
  end

  ## wire

  defp reply(id, result), do: write(%{"id" => id, "result" => result})

  defp error(id, code, message),
    do: write(%{"id" => id, "error" => %{"code" => code, "message" => message}})

  defp notify(method, params), do: write(%{"method" => method, "params" => params})

  defp request(id, method, params),
    do: write(%{"id" => id, "method" => method, "params" => params})

  defp write(msg) do
    IO.binwrite(:stdio, [JSON.encode!(msg), "\n"])
  end
end

FakeAppServer.main()
