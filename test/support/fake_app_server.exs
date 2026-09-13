# A scripted stand-in for `codex-app-server`, run with `elixir fake_app_server.exs`
# under Longx.Shim exactly like the real binary. Speaks newline-delimited
# JSON-RPC on stdio. Behaviour is chosen by the user text of `turn/start`:
#
#   "say <words>"      stream <words> as agentMessage deltas, complete the turn
#   "approve <cmd>"    ask the client to approve <cmd> (server → client request),
#                      then run or decline it depending on the answer
#   "ask <question>"   ask the client a question (item/tool/requestUserInput with one
#                      question `q1`), then say the answer back
#   "stall"            emit 3 deltas, wait for a `fake/continue` notification,
#                      then finish
#   "slow <ms>"        sleep <ms> before answering turn/start
#   "error"            answer turn/start with a JSON-RPC error
#   "die"              exit immediately (simulates a crash)
#   "server-notify"    emit a notification without a threadId
#   "name <title>"     codex names the thread: thread/name/updated, then a message
#   "spawn <name>"     a sub-agent: turn/plan/updated, subAgentActivity started on
#                      this thread, a child thread <name> (items on its own id: a
#                      command and an agentMessage "done by <name>"), a
#                      collabAgentToolCall wait, subAgentActivity completed
#
# Requests before the initialize/initialized handshake get "Not initialized".
#
# With FAKE_PERSIST=1 the ids of started threads are kept in ./fake_threads.txt
# (like codex keeps threads on disk), and thread/resume fails for ids that
# were never started — a restarted fake can then resume real threads only.

defmodule FakeAppServer do
  @persist_file "fake_threads.txt"

  def main do
    # ids unique per server process (like codex's UUIDs): the ETS-backed
    # ThreadState store outlives tests, so two fakes must never share ids
    loop(%{
      initialized: false,
      next: 1,
      prefix: System.pid(),
      threads: %{},
      pending: %{},
      persist: System.get_env("FAKE_PERSIST") == "1",
      known: load_known()
    })
  end

  defp load_known do
    case File.read(@persist_file) do
      {:ok, content} -> content |> String.split("\n", trim: true) |> MapSet.new()
      _ -> MapSet.new()
    end
  end

  # remember a thread id across restarts (FAKE_PERSIST=1)
  defp remember(%{persist: true, known: known} = state, thread_id) do
    File.write!(@persist_file, thread_id <> "\n", [:append])
    %{state | known: MapSet.put(known, thread_id)}
  end

  defp remember(state, _thread_id), do: state

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

  defp handle(%{"id" => id, "method" => "thread/start"} = msg, state) do
    thread_id = "thr_#{state.prefix}_#{state.next}"
    thread = %{"id" => thread_id, "preview" => "", "sessionId" => thread_id}
    reply(id, %{"thread" => thread})
    notify("thread/started", %{"thread" => thread})

    # the params are kept so tests can read back (thread/read) what a client sent
    %{
      state
      | next: state.next + 1,
        threads: Map.put(state.threads, thread_id, %{turns: [], params: msg["params"] || %{}})
    }
    |> remember(thread_id)
  end

  defp handle(
         %{"id" => id, "method" => "thread/resume", "params" => %{"threadId" => thread_id}},
         state
       ) do
    if state.persist and not MapSet.member?(state.known, thread_id) do
      error(id, -32602, "thread not found: #{thread_id}")
      state
    else
      thread = %{"id" => thread_id, "preview" => "", "sessionId" => thread_id}
      reply(id, %{"thread" => thread})
      notify("thread/started", %{"thread" => thread})
      %{state | threads: Map.put_new(state.threads, thread_id, %{turns: []})}
    end
  end

  # thread/revert: drop the given turn and everything after it (codex only allows this on paginated threads)
  defp handle(
         %{
           "id" => id,
           "method" => "thread/revert",
           "params" => %{"threadId" => thread_id, "beforeTurnId" => before}
         },
         state
       ) do
    turns = state.threads |> Map.get(thread_id, %{turns: []}) |> Map.get(:turns) |> Enum.reverse()

    case Enum.find_index(turns, &(&1["id"] == before)) do
      nil ->
        error(id, -32600, "unknown turn #{before}")
        state

      idx ->
        kept = Enum.take(turns, idx)

        reply(id, %{
          "thread" => %{"id" => thread_id, "turns" => []},
          "turnsBackwardsCursor" => nil,
          "itemsBackwardsCursor" => nil
        })

        notify("thread/reverted", %{"threadId" => thread_id})
        put_in(state, [:threads, thread_id, :turns], Enum.reverse(kept))
    end
  end

  # thread/fork: a new thread with the history up to and including lastTurnId
  defp handle(
         %{
           "id" => id,
           "method" => "thread/fork",
           "params" => %{"threadId" => thread_id} = params
         },
         state
       ) do
    turns = state.threads |> Map.get(thread_id, %{turns: []}) |> Map.get(:turns) |> Enum.reverse()

    kept =
      case params["lastTurnId"] do
        nil ->
          turns

        last ->
          Enum.take_while(turns, &(&1["id"] != last)) ++ Enum.filter(turns, &(&1["id"] == last))
      end

    new_id = "thr_#{state.prefix}_#{state.next}"

    thread = %{
      "id" => new_id,
      "preview" => "",
      "sessionId" => new_id,
      "forkedFromId" => thread_id
    }

    reply(id, %{"thread" => thread})
    notify("thread/started", %{"thread" => thread})

    %{
      state
      | next: state.next + 1,
        threads: Map.put(state.threads, new_id, %{turns: Enum.reverse(kept), params: params})
    }
    |> remember(new_id)
  end

  defp handle(
         %{"id" => id, "method" => "thread/read", "params" => %{"threadId" => thread_id}},
         state
       ) do
    entry = Map.get(state.threads, thread_id, %{turns: []})
    turns = entry |> Map.get(:turns) |> Enum.reverse()

    reply(id, %{
      "thread" => %{
        "id" => thread_id,
        "turns" => turns,
        # not part of codex's protocol: what this fake was asked for
        "startParams" => Map.get(entry, :params, %{}),
        "lastTurnParams" => Map.get(entry, :last_turn)
      }
    })

    state
  end

  defp handle(
         %{
           "id" => id,
           "method" => "turn/start",
           "params" => %{"threadId" => thread_id, "input" => input} = params
         },
         state
       ) do
    text = input |> List.first(%{}) |> Map.get("text", "")
    turn_id = "turn_#{state.prefix}_#{state.next}"

    threads =
      Map.update(
        state.threads,
        thread_id,
        %{turns: [], last_turn: params},
        &Map.put(&1, :last_turn, params)
      )

    state = %{state | next: state.next + 1, threads: threads}
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

  # fuzzyFileSearch: the files under the roots whose relative path contains
  # the query's characters in order (a real subsequence match, like codex)
  defp handle(
         %{
           "id" => id,
           "method" => "fuzzyFileSearch",
           "params" => %{"query" => q, "roots" => roots}
         },
         state
       ) do
    files =
      for root <- roots,
          q != "",
          file <- Path.wildcard(Path.join(root, "**/*"), match_dot: false),
          File.regular?(file),
          rel = Path.relative_to(file, root),
          subsequence?(String.downcase(q), String.downcase(rel)) do
        %{
          "root" => root,
          "path" => rel,
          "file_name" => Path.basename(rel),
          "match_type" => "file",
          "score" => max(1000 - String.length(rel), 1),
          "indices" => nil
        }
      end

    reply(id, %{"files" => Enum.sort_by(files, & &1["score"], :desc)})
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

  defp subsequence?("", _), do: true
  defp subsequence?(_, ""), do: false

  defp subsequence?(<<c, q::binary>>, <<c, s::binary>>), do: subsequence?(q, s)
  defp subsequence?(q, <<_, s::binary>>), do: subsequence?(q, s)

  ## turn scripts

  defp run_turn("say " <> words, id, thread_id, turn_id, state) do
    start_turn(id, thread_id, turn_id, "say " <> words)
    stream_message(thread_id, turn_id, String.split(words, " "))
    finish_turn(thread_id, turn_id, "completed", state, "say " <> words, words)
  end

  defp run_turn("approve " <> cmd, id, thread_id, turn_id, state) do
    start_turn(id, thread_id, turn_id, "approve " <> cmd)
    # codex numbers its server → client requests (JSON-RPC integer ids)
    request_id = state.next

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

  defp run_turn("ask " <> question, id, thread_id, turn_id, state) do
    start_turn(id, thread_id, turn_id, "ask " <> question)
    request_id = state.next

    request(request_id, "item/tool/requestUserInput", %{
      "threadId" => thread_id,
      "turnId" => turn_id,
      "itemId" => "call_#{state.next}",
      "isBlocking" => true,
      "questions" => [
        %{
          "id" => "q1",
          "header" => "Question",
          "question" => question,
          "options" => [
            %{"label" => "yes", "description" => "go ahead"},
            %{"label" => "no", "description" => "stop"}
          ],
          "isOther" => true
        }
      ]
    })

    continuation = fn
      %{"answers" => %{"q1" => %{"answers" => [answer | _]}}}, state ->
        stream_message(thread_id, turn_id, ["you said", answer])

        finish_turn(
          thread_id,
          turn_id,
          "completed",
          state,
          "ask " <> question,
          "you said " <> answer
        )

      _other, state ->
        stream_message(thread_id, turn_id, ["no answer"])
        finish_turn(thread_id, turn_id, "completed", state, "ask " <> question, "no answer")
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

  defp run_turn("spawn " <> name, id, thread_id, turn_id, state) do
    start_turn(id, thread_id, turn_id, "spawn " <> name)
    child_id = "#{thread_id}-#{name}"
    child_turn = "#{turn_id}-#{name}"

    notify("turn/plan/updated", %{
      "threadId" => thread_id,
      "turnId" => turn_id,
      "explanation" => "delegating",
      "plan" => [
        %{"step" => "spawn #{name}", "status" => "completed"},
        %{"step" => "wait for #{name}", "status" => "inProgress"},
        %{"step" => "report", "status" => "pending"}
      ]
    })

    activity = fn kind, n ->
      item = %{
        "id" => "act_#{name}_#{kind}_#{n}",
        "type" => "subAgentActivity",
        "agentPath" => "/root/#{name}",
        "agentThreadId" => child_id,
        "kind" => kind
      }

      notify("item/started", %{"threadId" => thread_id, "turnId" => turn_id, "item" => item})
      notify("item/completed", %{"threadId" => thread_id, "turnId" => turn_id, "item" => item})
    end

    activity.("started", state.next)

    # the child works on its own thread id (no thread/started for sub-agents)
    notify("turn/started", %{
      "threadId" => child_id,
      "turn" => %{"id" => child_turn, "status" => "inProgress"}
    })

    cmd = %{
      "id" => "cmd_#{name}",
      "type" => "commandExecution",
      "command" => "echo #{name}",
      "status" => "completed",
      "aggregatedOutput" => "#{name}\n",
      "exitCode" => 0
    }

    notify("item/started", %{
      "threadId" => child_id,
      "turnId" => child_turn,
      "item" => Map.put(cmd, "status", "inProgress")
    })

    notify("item/completed", %{"threadId" => child_id, "turnId" => child_turn, "item" => cmd})
    msg = %{"id" => "msg_#{name}", "type" => "agentMessage", "text" => "done by #{name}"}

    notify("item/started", %{
      "threadId" => child_id,
      "turnId" => child_turn,
      "item" => Map.put(msg, "text", "")
    })

    notify("item/completed", %{"threadId" => child_id, "turnId" => child_turn, "item" => msg})

    notify("turn/completed", %{
      "threadId" => child_id,
      "turn" => %{"id" => child_turn, "status" => "completed"}
    })

    wait = %{
      "id" => "collab_#{name}",
      "type" => "collabAgentToolCall",
      "tool" => "wait",
      "status" => "completed",
      "senderThreadId" => thread_id,
      "receiverThreadIds" => [child_id],
      "agentsStates" => %{child_id => %{"status" => "completed", "message" => "done by #{name}"}},
      "prompt" => nil,
      "model" => nil
    }

    notify("item/started", %{
      "threadId" => thread_id,
      "turnId" => turn_id,
      "item" => Map.put(wait, "status", "inProgress")
    })

    notify("item/completed", %{"threadId" => thread_id, "turnId" => turn_id, "item" => wait})
    activity.("completed", state.next)

    notify("turn/plan/updated", %{
      "threadId" => thread_id,
      "turnId" => turn_id,
      "explanation" => nil,
      "plan" => [
        %{"step" => "spawn #{name}", "status" => "completed"},
        %{"step" => "wait for #{name}", "status" => "completed"},
        %{"step" => "report", "status" => "inProgress"}
      ]
    })

    stream_message(thread_id, turn_id, ["#{name}", "reported"])
    finish_turn(thread_id, turn_id, "completed", state, "spawn " <> name, "#{name} reported")
  end

  defp run_turn("name " <> title, id, thread_id, turn_id, state) do
    start_turn(id, thread_id, turn_id, "name " <> title)
    notify("thread/name/updated", %{"threadId" => thread_id, "threadName" => title})
    finish_turn(thread_id, turn_id, "completed", state, "name " <> title, "named")
  end

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
