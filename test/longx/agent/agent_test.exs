defmodule Longx.AgentTest do
  use Longx.DataCase, async: false

  alias Longx.Agent
  alias Longx.Agent.Transcript
  alias Longx.AI
  alias Longx.Agent.ThreadState
  alias Longx.Test.ResponsesFixture

  setup do
    # nothing of a previous test may still be writing: every agent and every
    # tool / model task goes before the next test's sandbox starts
    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Longx.Agent.Supervisor),
          is_pid(pid),
          do: safe_stop(pid)

      for pid <- Task.Supervisor.children(Longx.Agent.TaskSupervisor),
          do: Task.Supervisor.terminate_child(Longx.Agent.TaskSupervisor, pid)
    end)

    Ash.bulk_destroy!(AI.Model, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(AI.Provider, :destroy, %{}, authorize?: false)

    bypass = Bypass.open()
    n = System.unique_integer([:positive])

    provider =
      AI.create_provider!(%{
        name: "Upstream #{n}",
        slug: "upstream-#{n}",
        base_url: "http://localhost:#{bypass.port}/v1",
        api_key: "sk-upstream"
      })

    model =
      AI.create_model!(%{
        name: "Fake",
        upstream_id: "real-model",
        slug: "fake-#{n}",
        provider_id: provider.id,
        context_window: 64_000
      })

    AI.make_default_model!(model)

    dir = Path.join(System.tmp_dir!(), "longx-agent-#{n}")
    File.mkdir_p!(dir)
    thread_id = "agent-thread-#{n}"
    :ok = ThreadState.subscribe(thread_id)

    on_exit(fn ->
      Agent.stop(thread_id)
      ThreadState.stop(thread_id)
      ThreadState.Store.delete(thread_id)
      File.rm_rf!(dir)
    end)

    {:ok, _pid} = Agent.ensure(thread_id: thread_id, cwd: dir, project_id: "p1")
    %{bypass: bypass, dir: dir, thread_id: thread_id, model: model}
  end

  ## helpers

  defp sse(conn, chunks) do
    conn =
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    Enum.reduce(chunks, conn, fn chunk, c ->
      {:ok, c} = Plug.Conn.chunk(c, chunk)
      c
    end)
  end

  defp body!(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    {Jason.decode!(body), conn}
  end

  # the replies, one per request, each `fn request_body, conn -> conn end`
  defp script!(bypass, replies) do
    {:ok, queue} = Elixir.Agent.start_link(fn -> replies end)
    test = self()

    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      {body, conn} = body!(conn)
      send(test, {:request, body})

      case Elixir.Agent.get_and_update(queue, fn [h | t] -> {h, t} end) do
        reply when is_function(reply, 2) -> reply.(body, conn)
        chunks when is_list(chunks) -> sse(conn, chunks)
      end
    end)
  end

  # a reply held until the test says :go (the handler pid is sent back)
  defp held(chunks) do
    test = self()

    fn _body, conn ->
      send(test, {:held, self()})

      receive do
        :go -> sse(conn, chunks)
      end
    end
  end

  defp await(method, timeout \\ 5_000) do
    receive do
      {:thread, _seq, ^method, params} -> params
    after
      timeout ->
        flunk("no #{method} event; got: #{inspect(mailbox_summary(), pretty: true, limit: 60)}")
    end
  end

  # the goal event that brings this status, the charges before it skipped
  defp await_goal_status(status) do
    case await("thread/goal/updated") do
      %{"goal" => %{"status" => ^status}} = params -> params
      _ -> await_goal_status(status)
    end
  end

  # what the mailbox held when an await ran out: the events, summarised
  defp mailbox_summary do
    {:messages, msgs} = Process.info(self(), :messages)

    for msg <- msgs do
      case msg do
        {:thread, _, method, %{"item" => %{"type" => t} = item}} ->
          {method, t, item["kind"] || item["content"]}

        {:thread, _, method, %{"turn" => turn}} ->
          {method, turn}

        {:thread, _, method, _} ->
          method

        {:request, body} ->
          {:request, last_text(body)}

        other ->
          other
      end
    end
  end

  defp await_turn_end(timeout \\ 5_000), do: await("turn/completed", timeout)["turn"]

  defp exec_call(command),
    do: ResponsesFixture.function_call("exec_command", nil, %{"cmd" => command})

  # a grammar-constrained (custom) tool call, as OpenAI's Responses API streams it
  defp custom_call(name, input) do
    call_id = "call_" <> Integer.to_string(System.unique_integer([:positive]))
    item_id = "ctc_" <> Integer.to_string(System.unique_integer([:positive]))
    resp = %{id: "resp_x", object: "response", created_at: 1, model: "fake-model", output: []}

    done = %{
      id: item_id,
      type: "custom_tool_call",
      call_id: call_id,
      name: name,
      input: input,
      status: "completed"
    }

    [
      %{type: "response.created", response: Map.put(resp, :status, "in_progress")},
      %{
        type: "response.output_item.added",
        output_index: 0,
        item: %{done | input: "", status: "in_progress"}
      },
      %{type: "response.output_item.done", output_index: 0, item: done},
      %{
        type: "response.completed",
        response:
          Map.merge(resp, %{
            status: "completed",
            output: [done],
            usage: %{input_tokens: 3, output_tokens: 2, total_tokens: 5}
          })
      }
    ]
    |> Enum.with_index()
    |> Enum.map(fn {event, seq} ->
      "event: #{event.type}\ndata: #{Jason.encode!(Map.put(event, :sequence_number, seq))}\n\n"
    end)
  end

  ## tests

  test "a question, an answer: events, transcript, request", %{bypass: bypass, thread_id: id} do
    script!(bypass, [ResponsesFixture.assistant_message("hello there")])

    assert {:ok, %{turn_id: turn_id, steered: false}} = Agent.send(id, "hi")

    assert %{"turn" => %{"id" => ^turn_id, "status" => "inProgress", "startedAt" => _}} =
             await("turn/started")

    assert %{"item" => %{"type" => "userMessage", "turnId" => ^turn_id} = um} =
             await("item/completed")

    assert [%{"type" => "text", "text" => "hi"}] = um["content"]

    assert %{"item" => %{"type" => "agentMessage", "id" => am}} =
             await_item_started("agentMessage")

    assert %{"itemId" => ^am, "delta" => "hello there"} = await("item/agentMessage/delta")
    assert %{"item" => %{"id" => ^am, "text" => "hello there"}} = await("item/completed")

    assert %{"tokenUsage" => %{"modelContextWindow" => 64_000, "last" => %{"inputTokens" => 12}}} =
             await("thread/tokenUsage/updated")

    # the turn carries its own stamps and its own token usage (the UI's per-turn
    # badge; the thread-level tokenUsage is only ever the last one)
    assert %{
             "id" => ^turn_id,
             "status" => "completed",
             "startedAt" => started,
             "completedAt" => completed,
             "usage" => usage
           } =
             await_turn_end()

    assert is_number(started) and is_number(completed) and completed >= started
    assert %{"inputTokens" => 12, "outputTokens" => _, "totalTokens" => _} = usage
    assert Agent.status(id) == :idle
    # the view keeps every turn, not only the last
    assert %{^turn_id => %{"status" => "completed", "usage" => ^usage}} =
             ThreadState.snapshot(id).turns

    assert_receive {:request, body}
    assert body["instructions"] =~ "You are"

    assert Enum.map(body["tools"], & &1["name"]) |> Enum.sort() ==
             ~w(apply_patch create_goal credential_create credential_login credential_rotate credentials_list exec_command get_context_remaining get_goal http_request knowledge_read knowledge_search knowledge_write new_context_window notify present prompt_user send_file show_diff show_file show_html update_goal view_image wait_until watch_enable watch_list watch_run web_fetch web_search)

    refute Map.has_key?(body, "x-longx-custom-tools")

    assert [%{"role" => "user", "content" => [%{"type" => "input_text", "text" => "hi"}]}] =
             body["input"]

    assert [%{kind: :user_message}, %{kind: :agent_message, model: "longx"}] =
             Transcript.items!(id)

    snapshot = ThreadState.snapshot(id)
    assert snapshot.thread["id"] == id
    assert length(snapshot.items) == 2
  end

  test "a tool call runs, streams its output and feeds the next request", %{
    bypass: bypass,
    thread_id: id,
    dir: dir
  } do
    script!(bypass, [exec_call("echo hi; pwd"), ResponsesFixture.assistant_message("done")])

    {:ok, %{turn_id: turn_id}} = Agent.send(id, "run it")

    assert %{
             "item" => %{
               "type" => "commandExecution",
               "id" => cmd,
               "command" => "echo hi; pwd",
               "status" => "inProgress"
             }
           } =
             await_item_started("commandExecution")

    assert %{"itemId" => ^cmd, "delta" => delta} = await("item/commandExecution/outputDelta")
    assert delta =~ "hi"

    # the completed item keeps what the started one said (the row's command text)
    assert %{
             "item" => %{
               "id" => ^cmd,
               "status" => "completed",
               "exitCode" => 0,
               "aggregatedOutput" => out,
               "command" => "echo hi; pwd"
             }
           } = await_item_completed(cmd)

    assert out =~ dir
    assert %{"id" => ^turn_id, "status" => "completed"} = await_turn_end()

    assert_receive {:request, _first}
    assert_receive {:request, second}

    assert [
             %{"role" => "user"},
             %{"type" => "function_call", "name" => "exec_command", "call_id" => call_id},
             %{"type" => "function_call_output", "call_id" => call_id, "output" => output}
           ] = second["input"]

    assert output =~ "hi\n"

    kinds = Transcript.items!(id) |> Enum.map(& &1.kind)
    assert kinds == [:user_message, :function_call, :function_call_output, :agent_message]
  end

  # two calls in one response, as a model makes them in parallel
  defp two_calls(a, b) do
    resp = %{id: "resp_2", object: "response", created_at: 1, model: "fake-model", output: []}

    items =
      for {{name, args}, i} <- Enum.with_index([a, b]) do
        %{
          id: "fc_#{i}_#{System.unique_integer([:positive])}",
          type: "function_call",
          call_id: "call_#{i}_#{System.unique_integer([:positive])}",
          name: name,
          arguments: Jason.encode!(args),
          status: "completed"
        }
      end

    ([%{type: "response.created", response: Map.put(resp, :status, "in_progress")}] ++
       Enum.flat_map(Enum.with_index(items), fn {item, i} ->
         [
           %{
             type: "response.output_item.added",
             output_index: i,
             item: %{item | arguments: "", status: "in_progress"}
           },
           %{type: "response.output_item.done", output_index: i, item: item}
         ]
       end) ++
       [
         %{
           type: "response.completed",
           response:
             Map.merge(resp, %{
               status: "completed",
               output: items,
               usage: %{input_tokens: 3, output_tokens: 2, total_tokens: 5}
             })
         }
       ])
    |> Enum.with_index()
    |> Enum.map(fn {event, seq} ->
      "event: #{event.type}\ndata: #{Jason.encode!(Map.put(event, :sequence_number, seq))}\n\n"
    end)
  end

  test "an image attached by a tool goes in after every output of the step, never between them",
       %{bypass: bypass, thread_id: id, dir: dir} do
    File.write!(Path.join(dir, "shot.png"), <<0x89, ?P, ?N, ?G, 13, 10, 26, 10>>)

    script!(bypass, [
      two_calls(
        {"view_image", %{"path" => "shot.png"}},
        {"exec_command", %{"cmd" => "sleep 0.2; echo later"}}
      ),
      ResponsesFixture.assistant_message("seen")
    ])

    {:ok, %{turn_id: turn_id}} = Agent.send(id, "look")
    assert %{"id" => ^turn_id, "status" => "completed"} = await_turn_end()
    assert_receive {:request, _first}
    assert_receive {:request, second}

    assert [
             %{"role" => "user"},
             %{"type" => "function_call"},
             %{"type" => "function_call"},
             %{"type" => "function_call_output"},
             %{"type" => "function_call_output"},
             %{
               "role" => "user",
               "content" => [
                 %{"type" => "input_image", "image_url" => "data:image/png;base64," <> _}
               ]
             }
           ] = second["input"]
  end

  test "a custom tool call (OpenAI's freeform apply_patch) is applied and answered in kind", %{
    bypass: bypass,
    thread_id: id,
    dir: dir
  } do
    File.write!(Path.join(dir, "n.txt"), "old\n")
    patch = "*** Begin Patch\n*** Update File: n.txt\n@@\n-old\n+new\n*** End Patch\n"

    script!(bypass, [
      custom_call("apply_patch", patch),
      ResponsesFixture.assistant_message("patched")
    ])

    {:ok, %{turn_id: turn_id}} = Agent.send(id, "patch it")

    assert %{
             "item" => %{"type" => "fileChange", "id" => fc, "changes" => [%{"kind" => "update"}]}
           } =
             await_item_started("fileChange")

    assert %{"item" => %{"id" => ^fc, "status" => "completed", "changes" => [%{"diff" => diff}]}} =
             await_item_completed(fc)

    assert diff =~ "-old\n+new"
    assert %{"id" => ^turn_id, "status" => "completed"} = await_turn_end()
    assert File.read!(Path.join(dir, "n.txt")) == "new\n"

    assert_receive {:request, _first}
    assert_receive {:request, second}

    assert [
             _,
             %{"type" => "custom_tool_call", "name" => "apply_patch"},
             %{"type" => "custom_tool_call_output", "output" => "Done!" <> _}
           ] =
             second["input"]
  end

  test "a message during a turn steers it: the model sees it at the next step", %{
    bypass: bypass,
    thread_id: id
  } do
    script!(bypass, [
      held(ResponsesFixture.assistant_message("one")),
      ResponsesFixture.assistant_message("two")
    ])

    {:ok, %{turn_id: turn_id}} = Agent.send(id, "first")
    assert_receive {:held, handler}, 5_000

    assert {:ok, %{turn_id: ^turn_id, steered: true}} = Agent.send(id, "also this")
    # not in the transcript yet: it shows when the kernel folds it into the next step
    refute_receive {:thread, _, "item/completed",
                    %{
                      "item" => %{
                        "type" => "userMessage",
                        "content" => [%{"text" => "also this"}]
                      }
                    }},
                   200

    send(handler, :go)
    assert %{"turnId" => ^turn_id} = await_user_message("also this")
    assert %{"id" => ^turn_id, "status" => "completed"} = await_turn_end()

    assert_receive {:request, _first}
    assert_receive {:request, second}
    texts = for %{"role" => "user", "content" => [%{"text" => t}]} <- second["input"], do: t
    assert texts == ["first", "also this"]

    assert [%{"type" => "text", "text" => "one"}] = last_agent_text(id) |> Enum.take(1)
  end

  test "a message to be delivered when idle waits in the mailbox while a turn runs and starts a turn of its own after it",
       %{bypass: bypass, thread_id: id} do
    script!(bypass, [
      held(ResponsesFixture.assistant_message("one")),
      ResponsesFixture.assistant_message("two")
    ])

    {:ok, %{turn_id: turn_id}} = Agent.send(id, "first")
    assert_receive {:thread, _, "turn/started", %{"turn" => %{"id" => ^turn_id}}}, 5_000
    assert_receive {:held, handler}, 5_000

    # not a steer: the running turn never sees it
    assert :ok = Agent.send(id, "later", deliver: :idle, from: "watch-x")
    assert {:running, ^turn_id} = Agent.status(id)

    refute_receive {:thread, _, "item/completed",
                    %{
                      "item" => %{
                        "type" => "userMessage",
                        "content" => [%{"text" => "[agent" <> _}]
                      }
                    }},
                   200

    send(handler, :go)
    assert %{"id" => ^turn_id, "status" => "completed"} = await_turn_end()

    # the postponed message comes out of the mailbox as the next turn
    assert_receive {:thread, _, "turn/started", %{"turn" => %{"id" => second}}}, 5_000
    assert second != turn_id
    assert %{"from" => "watch-x"} = await_user_message("[agent watch-x] later")
    assert %{"id" => ^second, "status" => "completed"} = await_turn_end()

    assert_receive {:request, first}
    assert_receive {:request, body}
    texts = for %{"role" => "user", "content" => [%{"text" => t}]} <- first["input"], do: t
    assert texts == ["first"]
    texts = for %{"role" => "user", "content" => [%{"text" => t}]} <- body["input"], do: t
    assert texts == ["first", "[agent watch-x] later"]

    # idle: delivered at once, a turn like any other
    script!(bypass, [ResponsesFixture.assistant_message("three")])
    assert :ok = Agent.send(id, "now", deliver: :idle, from: "watch-x")
    await_user_message("[agent watch-x] now")
    assert %{"status" => "completed"} = await_turn_end()
  end

  test "a malformed call never takes the agent down: exec_command's object wrapped under cmd is unwrapped, a cmd that is no string is that call's error (a child once died mid-turn on a map where a string was expected)",
       %{bypass: bypass, thread_id: id} do
    script!(bypass, [
      # codex's own exec_command arguments object, wrapped under `cmd` by the model
      ResponsesFixture.function_call("exec_command", nil, %{
        "cmd" => %{
          "cmd" => "echo unwrapped",
          "max_output_tokens" => 5000,
          "yield_time_ms" => 1000
        }
      }),
      ResponsesFixture.function_call("exec_command", nil, %{"cmd" => %{"nope" => 1}}),
      ResponsesFixture.assistant_message("done")
    ])

    {:ok, %{turn_id: turn_id}} = Agent.send(id, "go")

    assert %{"item" => %{"command" => "echo unwrapped", "status" => "completed"} = first} =
             await_item_completed_of_type("commandExecution")

    assert first["aggregatedOutput"] =~ "unwrapped"

    assert %{"item" => %{"status" => "failed", "command" => command}} =
             await_item_completed_of_type("commandExecution")

    assert command =~ "nope"
    assert %{"id" => ^turn_id, "status" => "completed"} = await_turn_end()
    assert is_pid(Agent.whereis(id))

    [_, _, third] = collect_requests([])

    # the schema's own refusal reaches the model (`#/cmd: Type mismatch. Expected String`)
    assert Enum.any?(third["input"], fn item ->
             item["type"] == "function_call_output" and item["output"] =~ ~r/cmd.*Expected String/
           end)
  end

  defmodule BoomTool do
    use Longx.Agent.Plug

    tool :boom, "raises while preparing its arguments", prepare: &__MODULE__.explode/1 do
      param :x, :string, "anything"
    end

    def explode(_args), do: raise("bad arguments")
    def boom(_args, _ctx), do: {:ok, "never"}
  end

  defmodule BoomPipeline do
    use Longx.Agent.Pipeline
    plug BoomTool
    plug Longx.Agent.Plugs.Request
  end

  test "a tool whose preparation raises fails that call only; the agent lives on", %{
    bypass: bypass,
    dir: dir
  } do
    id = agent!("boom-#{System.unique_integer([:positive])}", dir, pipeline: BoomPipeline)

    script!(bypass, [
      ResponsesFixture.function_call("boom", nil, %{"x" => "y"}),
      ResponsesFixture.assistant_message("survived")
    ])

    {:ok, %{turn_id: turn_id}} = Agent.send(id, "go")
    assert %{"item" => %{"status" => "failed"}} = await_item_completed_of_type("dynamicToolCall")
    assert %{"id" => ^turn_id, "status" => "completed"} = await_turn_end()
    assert is_pid(Agent.whereis(id))

    [_, second] = collect_requests([])

    assert Enum.any?(second["input"], fn item ->
             item["type"] == "function_call_output" and item["output"] =~ "bad arguments"
           end)
  end

  test "a call's arguments streaming in is progress the thread shows: the tool's name and the bytes so far, gone once the call runs",
       %{bypass: bypass, thread_id: id} do
    script!(bypass, [
      ResponsesFixture.function_call("exec_command", nil, %{
        "cmd" => "echo " <> String.duplicate("x", 3_000)
      }),
      ResponsesFixture.assistant_message("done")
    ])

    {:ok, _} = Agent.send(id, "run it")

    # the call opened: its name is known before a byte of its arguments
    assert_receive {:thread, _, "turn/progress",
                    %{
                      "progress" => %{
                        "kind" => "toolCall",
                        "name" => "exec_command",
                        "bytes" => 0
                      }
                    }},
                   5_000

    # the arguments came: the bytes grew
    assert_receive {:thread, _, "turn/progress",
                    %{"progress" => %{"name" => "exec_command", "bytes" => bytes}}}
                   when bytes > 3_000,
                   5_000

    # the call ran: no progress to show; the view says so too
    assert_receive {:thread, _, "turn/progress", %{"progress" => nil}}, 5_000
    assert %{"status" => "completed"} = await_turn_end()
    assert ThreadState.snapshot(id).progress == nil
  end

  test "a stream that breaks mid-turn is retried: the person sees the retry as progress and the turn completes; past the retries the turn fails naming the model so another can take over",
       %{bypass: bypass, dir: dir, model: model} do
    settings = Map.put(Longx.Agent.Definition.Settings.defaults(), :model_retries, 1)
    id = agent!("retry-#{System.unique_integer([:positive])}", dir, settings: fn -> settings end)
    [created, added, delta | _] = ResponsesFixture.assistant_message("hello there")
    {:ok, counter} = Elixir.Agent.start_link(fn -> 0 end)

    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      n = Elixir.Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      # the first stream drops after a few events; the second is whole
      if n == 1,
        do: sse(conn, [created, added, delta]),
        else: sse(conn, ResponsesFixture.assistant_message("hello there"))
    end)

    {:ok, _} = Agent.send(id, "hi")

    assert_receive {:thread, _, "turn/progress",
                    %{"progress" => %{"kind" => "retry", "name" => why}}},
                   5_000

    assert why =~ "ended"
    assert %{"status" => "completed"} = await_turn_end()
    assert Elixir.Agent.get(counter, & &1) == 2

    # every stream breaks: one retry (the setting), then the turn fails with the model's name
    Elixir.Agent.update(counter, fn _ -> 0 end)

    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      Elixir.Agent.update(counter, &(&1 + 1))
      sse(conn, [created, added, delta])
    end)

    {:ok, _} = Agent.send(id, "again")
    assert %{"status" => "failed", "error" => error} = await_turn_end(10_000)
    assert %{"code" => "model_failed", "model" => slug, "message" => message} = error
    assert slug == model.slug
    assert message =~ "ended"
    assert Elixir.Agent.get(counter, & &1) == 2
  end

  test "interrupt ends the turn at once; the late reply is ignored; the thread goes on", %{
    bypass: bypass,
    thread_id: id
  } do
    script!(bypass, [
      held(ResponsesFixture.assistant_message("late")),
      ResponsesFixture.assistant_message("again")
    ])

    {:ok, %{turn_id: turn_id}} = Agent.send(id, "slow one")
    assert_receive {:held, handler}, 5_000

    assert :ok = Agent.interrupt(id)
    # the held handler dies with the connection the interrupt closed: not a failure
    Bypass.pass(bypass)
    assert %{"id" => ^turn_id, "status" => "interrupted"} = await_turn_end()
    assert Agent.status(id) == :idle
    assert {:error, :not_running} = Agent.interrupt(id)

    send(handler, :go)
    refute_receive {:thread, _, "item/agentMessage/delta", _}, 300

    {:ok, %{turn_id: t2}} = Agent.send(id, "next")
    assert %{"id" => ^t2, "status" => "completed"} = await_turn_end()
    assert_receive {:request, _}
    assert_receive {:request, body}
    assert length(body["input"]) == 2
  end

  test "a restart rebuilds the view and the context from the transcript", %{
    bypass: bypass,
    thread_id: id,
    dir: dir
  } do
    script!(bypass, [
      ResponsesFixture.assistant_message("remembered"),
      ResponsesFixture.assistant_message("yes")
    ])

    {:ok, _} = Agent.send(id, "remember this")
    await_turn_end()

    :ok = Agent.stop(id)
    :ok = ThreadState.stop(id)
    :ok = ThreadState.Store.delete(id)

    {:ok, _} = Agent.ensure(thread_id: id, cwd: dir, project_id: "p1")
    snapshot = ThreadState.snapshot(id)
    assert snapshot.thread["id"] == id
    assert Enum.map(snapshot.items, & &1["type"]) == ["userMessage", "agentMessage"]

    {:ok, _} = Agent.send(id, "did you?")
    await_turn_end()
    assert_receive {:request, _}
    assert_receive {:request, body}
    assert length(body["input"]) == 3
  end

  test "a retract drops the turn from the transcript and the view", %{
    bypass: bypass,
    thread_id: id
  } do
    script!(bypass, [
      held(ResponsesFixture.assistant_message("never")),
      ResponsesFixture.assistant_message("fresh")
    ])

    {:ok, %{turn_id: turn_id}} = Agent.send(id, "oops")
    assert_receive {:held, handler}, 5_000

    assert :ok = Agent.retract(id, turn_id)
    Bypass.pass(bypass)
    assert %{"turnIds" => [^turn_id]} = await("thread/reverted")
    assert %{"id" => ^turn_id, "status" => "interrupted"} = await_turn_end()
    assert Transcript.items!(id) == []
    assert ThreadState.snapshot(id).items == []
    send(handler, :go)

    {:ok, _} = Agent.send(id, "fresh start")
    await_turn_end()
    assert_receive {:request, _}
    assert_receive {:request, body}
    assert [%{"content" => [%{"text" => "fresh start"}]}] = body["input"]
  end

  test "a model failure fails the turn with the message", %{bypass: bypass, thread_id: id} do
    script!(bypass, [
      fn _body, conn -> Plug.Conn.send_resp(conn, 400, ~s({"error":{"message":"nope"}})) end
    ])

    {:ok, %{turn_id: turn_id}} = Agent.send(id, "hi")

    assert %{"id" => ^turn_id, "status" => "failed", "error" => %{"message" => message}} =
             await_turn_end()

    assert message =~ "nope"
  end

  defmodule TestsAfterEdit do
    use Longx.Agent.Plug

    # a step that called nothing gets a command of the plug's own, once per turn
    def call(%Step{phase: :response, calls: []} = step, _) do
      checked? =
        Enum.any?(
          step.transcript,
          &(&1["type"] == "function_call_output" and is_binary(&1["output"]) and
              String.ends_with?(&1["output"], "Output:\nchecked\n"))
        )

      if checked?,
        do: step,
        else: Step.enqueue_call(step, "exec_command", %{"cmd" => "echo checked"})
    end

    def call(step, _), do: step
  end

  defmodule OneMoreStep do
    use Longx.Agent.Plug

    # continues the turn once: the second time the marker is in the context
    def call(%Step{phase: :turn_end} = step, _) do
      if Enum.any?(step.transcript, &(&1["role"] == "user" and text_of(&1) == "one more")),
        do: step,
        else: Step.continue(step, "one more", origin: %{"kind" => "goal", "round" => 1})
    end

    def call(step, _), do: step

    defp text_of(%{"content" => [%{"text" => t} | _]}), do: t
    defp text_of(_), do: nil
  end

  defmodule EffectsPipeline do
    use Longx.Agent.Pipeline
    plug Longx.Agent.Plugs.Shell
    plug TestsAfterEdit
    plug OneMoreStep
    plug Longx.Agent.Plugs.Request
  end

  test "response and turn-end plugs steer the loop: a synthetic call, then a continuation", %{
    bypass: bypass,
    dir: dir
  } do
    id = "effects-#{System.unique_integer([:positive])}"
    :ok = ThreadState.subscribe(id)

    on_exit(fn ->
      Agent.stop(id)
      ThreadState.stop(id)
      ThreadState.Store.delete(id)
    end)

    {:ok, _} = Agent.ensure(thread_id: id, cwd: dir, pipeline: EffectsPipeline)

    script!(bypass, [
      ResponsesFixture.assistant_message("first answer"),
      ResponsesFixture.assistant_message("after the check"),
      ResponsesFixture.assistant_message("after one more"),
      ResponsesFixture.assistant_message("after the second check")
    ])

    {:ok, %{turn_id: turn_id}} = Agent.send(id, "go")

    # step 1: the model called nothing → the response plug's command runs
    assert %{"item" => %{"type" => "commandExecution", "command" => "echo checked", "id" => cmd}} =
             await_item_started("commandExecution")

    assert %{"item" => %{"id" => ^cmd, "status" => "completed"}} = await_item_completed(cmd)
    # the turn would end → the turn-end plug continues it with its own message,
    # the UI item saying it is the kernel's (the page draws a marker, not the person's bubble)
    assert %{"turnId" => ^turn_id, "origin" => %{"kind" => "goal", "round" => 1}} =
             await_user_message("one more")

    assert %{"id" => ^turn_id, "status" => "completed"} = await_turn_end()

    requests = collect_requests([])
    assert length(requests) == 3
    third = Enum.at(requests, 2)

    assert [
             %{"role" => "user"},
             %{"role" => "assistant"},
             %{"type" => "function_call", "name" => "exec_command", "call_id" => "longx_" <> _},
             %{"type" => "function_call_output", "output" => "Exit code: 0\nWall time: " <> _},
             %{"role" => "assistant"},
             %{"role" => "user", "content" => [%{"text" => "one more"}]}
           ] = third["input"]
  end

  defmodule Forever do
    use Longx.Agent.Plug

    def call(%Step{phase: :response} = step, _),
      do: Step.enqueue_call(step, "exec_command", %{"cmd" => "true"})

    def call(step, _), do: step
  end

  defmodule ForeverPipeline do
    use Longx.Agent.Pipeline
    plug Longx.Agent.Plugs.Shell
    plug Forever
    plug Longx.Agent.Plugs.Request
  end

  test "a loop that never ends is cut at the step limit", %{bypass: bypass, dir: dir} do
    previous = Application.get_env(:longx, Longx.Agent, [])
    Application.put_env(:longx, Longx.Agent, Keyword.put(previous, :max_steps, 3))
    on_exit(fn -> Application.put_env(:longx, Longx.Agent, previous) end)

    id = "forever-#{System.unique_integer([:positive])}"
    :ok = ThreadState.subscribe(id)

    on_exit(fn ->
      Agent.stop(id)
      ThreadState.stop(id)
      ThreadState.Store.delete(id)
    end)

    {:ok, _} = Agent.ensure(thread_id: id, cwd: dir, pipeline: ForeverPipeline)
    script!(bypass, List.duplicate(ResponsesFixture.assistant_message("again"), 10))

    {:ok, %{turn_id: turn_id}} = Agent.send(id, "go")

    assert %{"id" => ^turn_id, "status" => "failed", "error" => %{"message" => message}} =
             await_turn_end(15_000)

    assert message =~ "3 steps"
    assert length(collect_requests([])) == 3
  end

  test "with no pipeline given the layered definition is loaded per step; a trusted .longx shapes the prompt and the tools; a broken file becomes a notice",
       %{bypass: bypass, dir: dir} do
    File.mkdir_p!(Path.join(dir, ".longx/plugs"))

    File.write!(Path.join(dir, ".longx/plugs/deploy.exs"), """
    defmodule Deploy do
      use Longx.Agent.Plug
      tool :deploy, "ships it" do
        param :env, :string, "target", required: true
      end
      def deploy(%{"env" => env}, _ctx), do: {:ok, "shipped to " <> env}
    end
    """)

    File.write!(Path.join(dir, ".longx/agent.exs"), """
    import Longx.Agent.Config
    agent do
      prompt "SECRET_MARK: always say hello"
      plug Deploy
    end
    """)

    id = "local-#{System.unique_integer([:positive])}"
    :ok = ThreadState.subscribe(id)

    on_exit(fn ->
      Agent.stop(id)
      ThreadState.stop(id)
      ThreadState.Store.delete(id)
    end)

    {:ok, _} = Agent.ensure(thread_id: id, cwd: dir, project_id: "p-local", trust: fn -> true end)

    script!(bypass, [
      ResponsesFixture.assistant_message("hi"),
      ResponsesFixture.assistant_message("hi again")
    ])

    {:ok, _} = Agent.send(id, "one")
    assert %{"status" => "completed"} = await_turn_end()
    assert_receive {:request, body}
    assert body["instructions"] =~ "SECRET_MARK"
    assert body["instructions"] =~ "Your own definition"
    assert "deploy" in Enum.map(body["tools"], & &1["name"])

    # the agent breaks its own plug: the next turn still runs, with a notice up front
    File.write!(Path.join(dir, ".longx/plugs/deploy.exs"), "defmodule Deploy do\n  oops(\n")
    File.touch!(Path.join(dir, ".longx/plugs/deploy.exs"), System.os_time(:second) + 5)

    {:ok, _} = Agent.send(id, "two")
    assert %{"status" => "completed"} = await_turn_end()
    assert_receive {:request, body}
    assert body["instructions"] =~ "⚠"
    assert body["instructions"] =~ "deploy.exs"
    refute "deploy" in Enum.map(body["tools"], & &1["name"])
  end

  test "the agent is told which models it may name; an unknown one in its description is a notice, not a failed turn",
       %{bypass: bypass, dir: dir} do
    File.mkdir_p!(Path.join(dir, ".longx/local"))

    File.write!(
      Path.join(dir, ".longx/local/agent.exs"),
      "import Longx.Agent.Config\nagent do\n  model \"qwen-max\"\nend\n"
    )

    choices = [
      %{
        slug: "fake-x",
        name: "Fake X",
        provider: "Upstream",
        levels: ["low", "high"],
        default_level: "low",
        default?: true
      },
      %{
        slug: "fake-y",
        name: "Fake Y",
        provider: "Upstream",
        levels: [],
        default_level: nil,
        default?: false
      }
    ]

    id = agent!("models-#{System.unique_integer([:positive])}", dir, models: fn -> choices end)
    script!(bypass, [ResponsesFixture.assistant_message("ok")])
    {:ok, _} = Agent.send(id, "hi")
    assert %{"status" => "completed"} = await_turn_end()
    assert_receive {:request, body}

    # the default model, not the unknown one (the gateway resolved the placeholder); the notice names both
    assert body["model"] == "real-model"
    assert body["instructions"] =~ "⚠"
    assert body["instructions"] =~ "qwen-max"
    assert body["instructions"] =~ "fake-x"
    # the list the agent may choose from, with levels and the default marked
    assert body["instructions"] =~ "# Models"
    assert body["instructions"] =~ "fake-x"
    assert body["instructions"] =~ "low, high"
  end

  test "the description's level stands under a level its model does not declare (a new thread once froze the default model's level and ran the description's model at it)",
       %{bypass: bypass, dir: dir, model: model} do
    described =
      AI.create_model!(%{
        name: "Described",
        upstream_id: "real-model-d",
        slug: "described-#{System.unique_integer([:positive])}",
        provider_id: model.provider_id,
        reasoning_levels: ["low", "medium", "xhigh"],
        reasoning_effort: "xhigh"
      })

    File.mkdir_p!(Path.join(dir, ".longx/local"))

    File.write!(
      Path.join(dir, ".longx/local/agent.exs"),
      "import Longx.Agent.Config\nagent do\n  model #{inspect(described.slug)}, effort: \"low\"\nend\n"
    )

    # the default model's level, frozen onto the thread: not one of the described model's
    id =
      agent!("level-#{System.unique_integer([:positive])}", dir,
        effort: "high",
        models: &AI.model_choices/0
      )

    script!(bypass, [ResponsesFixture.assistant_message("ok")])
    {:ok, _} = Agent.send(id, "hi")
    assert %{"status" => "completed"} = await_turn_end()
    assert_receive {:request, body}
    assert body["model"] == "real-model-d"
    assert body["reasoning"]["effort"] == "low"
  end

  test "a model chain: the first model's quota is gone, the turn goes on with the next and the view says so",
       %{bypass: bypass, dir: dir, model: model} do
    second =
      AI.create_model!(%{
        name: "Second",
        upstream_id: "real-model-2",
        slug: "second-#{System.unique_integer([:positive])}",
        provider_id: model.provider_id
      })

    {:ok, _} = Longx.AI.Aliases.put("ultra", [model.slug, second.slug])
    id = agent!("chain-#{System.unique_integer([:positive])}", dir, pipeline: EffectsPipeline)

    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      {body, conn} = body!(conn)

      case body["model"] do
        "real-model" ->
          Plug.Conn.send_resp(conn, 429, ~s({"error":{"message":"quota exhausted"}}))

        "real-model-2" ->
          sse(conn, ResponsesFixture.assistant_message("served"))
      end
    end)

    {:ok, _} = Agent.send(id, "hi", model: "ultra")

    assert %{"fromModel" => from, "toModel" => to, "reason" => reason} =
             await("model/rerouted")

    assert {from, to} == {model.slug, second.slug}
    assert reason =~ "quota"
    # the turn's badge follows the model that serves
    assert_receive {:thread, _, "turn/model", %{"model" => ^to}}, 5_000
    assert %{"status" => "completed"} = await_turn_end()
  end

  defmodule Progress do
    use Longx.Agent.Plug

    tool :scan, "scans the tree" do
    end

    # a plug's own card, without the model: Context.present mid-tool, and the
    # result's "present" key as the same thing after
    def scan(_args, ctx) do
      :ok = Context.present(ctx, %{"$type" => "Fact", "label" => "scanned", "value" => "3"})
      {:ok, "3 files", %{"present" => %{"$type" => "Text", "value" => "done"}}}
    end
  end

  defmodule PresentingPipeline do
    use Longx.Agent.Pipeline
    plug Longx.Agent.Plugs.Present
    plug Progress
    plug Longx.Agent.Plugs.Request
  end

  @tree %{
    "$type" => "Card",
    "title" => "Q3",
    "children" => [%{"$type" => "Fact", "label" => "Bookings", "value" => "1.2M"}]
  }

  test "present: the model's tree is the item the person sees; the model only reads that it was shown",
       %{bypass: bypass, dir: dir} do
    id =
      agent!("present-#{System.unique_integer([:positive])}", dir, pipeline: PresentingPipeline)

    route!(bypass, fn body ->
      if List.last(body["input"])["type"] == "function_call_output",
        do: ResponsesFixture.assistant_message("there it is"),
        else: ResponsesFixture.function_call("present", nil, @tree)
    end)

    {:ok, _} = Agent.send(id, "show q3")

    assert %{"namespace" => "longx", "tool" => "present", "arguments" => @tree, "success" => true} =
             await_tool_item("present")

    assert %{"status" => "completed"} = await_turn_end()
    last = List.last(collect_requests([]))

    assert Enum.any?(
             last["input"],
             &(&1["type"] == "function_call_output" and &1["output"] == "shown to the user")
           )
  end

  test "show_file: the item carries the resolved path in details; the model reads that it opened",
       %{bypass: bypass, dir: dir} do
    File.write!(Path.join(dir, "notes.md"), "# notes\n")
    id = agent!("show-#{System.unique_integer([:positive])}", dir, pipeline: PresentingPipeline)

    route!(bypass, fn body ->
      if List.last(body["input"])["type"] == "function_call_output",
        do: ResponsesFixture.assistant_message("opened"),
        else:
          ResponsesFixture.function_call("show_file", nil, %{"path" => "./notes.md", "line" => 1})
    end)

    {:ok, _} = Agent.send(id, "show the notes")

    assert %{
             "namespace" => "longx",
             "tool" => "show_file",
             "success" => true,
             "details" => %{"path" => "notes.md", "line" => 1}
           } = await_tool_item("show_file")

    assert %{"status" => "completed"} = await_turn_end()
    last = List.last(collect_requests([]))

    assert Enum.any?(
             last["input"],
             &(&1["type"] == "function_call_output" and &1["output"] =~ "opened notes.md")
           )
  end

  test "prompt_user: the ask carries the tree; the person's action answers the tool; a dismissal is an error the model reads",
       %{bypass: bypass, dir: dir} do
    id = agent!("prompt-#{System.unique_integer([:positive])}", dir, pipeline: PresentingPipeline)

    form = %{
      "$type" => "Card",
      "title" => "Which one?",
      "asForm" => true,
      "confirm" => %{"label" => "Go", "$action" => %{"type" => "pick"}},
      "children" => [
        %{
          "$type" => "Select",
          "name" => "env",
          "options" => [%{"label" => "A", "value" => "a"}, %{"label" => "B", "value" => "b"}]
        }
      ]
    }

    route!(bypass, fn body ->
      if List.last(body["input"])["type"] == "function_call_output",
        do: ResponsesFixture.assistant_message("noted"),
        else: ResponsesFixture.function_call("prompt_user", nil, form)
    end)

    {:ok, _} = Agent.send(id, "ask me")
    assert %{"requestId" => rid, "spec" => ^form} = await("longx/action/request")

    assert %{"tool" => "prompt_user", "status" => "inProgress"} =
             await_tool_item("prompt_user", "item/started")

    action = %{"type" => "pick", "$input" => %{"env" => "b"}}
    assert :ok = Agent.respond(id, rid, %{"action" => action})
    assert %{"status" => "completed"} = await_turn_end()
    last = List.last(collect_requests([]))

    assert Enum.any?(
             last["input"],
             &(&1["type"] == "function_call_output" and &1["output"] == Jason.encode!(action))
           )

    # dismissed: the model is told, and goes on
    {:ok, _} = Agent.send(id, "again")
    assert %{"requestId" => rid2} = await("longx/action/request")
    assert :ok = Agent.respond(id, rid2, %{"cancelled" => true})
    assert %{"status" => "completed"} = await_turn_end()
    last = List.last(collect_requests([]))

    assert Enum.any?(
             last["input"],
             &(&1["type"] == "function_call_output" and &1["output"] =~ "dismissed")
           )
  end

  test "Context.present: a plug's own card shows on the thread and is never in the model's context",
       %{bypass: bypass, dir: dir} do
    id =
      agent!("ctx-present-#{System.unique_integer([:positive])}", dir,
        pipeline: PresentingPipeline
      )

    route!(bypass, fn body ->
      if List.last(body["input"])["type"] == "function_call_output",
        do: ResponsesFixture.assistant_message("done"),
        else: ResponsesFixture.function_call("scan", nil, %{})
    end)

    {:ok, _} = Agent.send(id, "scan")

    # the card pushed mid-tool, then the one from the result — both completed longx.present items
    assert %{"arguments" => %{"$type" => "Fact", "label" => "scanned"}} =
             await_tool_item("present")

    assert %{"arguments" => %{"$type" => "Text", "value" => "done"}} = await_tool_item("present")
    assert %{"status" => "completed"} = await_turn_end()

    items = Transcript.items!(id)
    assert Enum.count(items, &(&1.kind == :activity)) == 2
    refute Enum.any?(Transcript.input(items), &is_map_key(&1, "$type"))
    # the view keeps them, the model never saw one
    last = List.last(collect_requests([]))
    refute Enum.any?(last["input"], &is_map_key(&1, "$type"))
    assert Enum.count(ThreadState.snapshot(id).items, &(&1["tool"] == "present")) == 2
  end

  defmodule Login do
    use Longx.Agent.Plug

    tool :login, "signs the person in", timeout: 60_000 do
    end

    # what a plug does when the person has to act: a request on the thread, a
    # callback URL for the browser to come back to, the answer as the result
    def login(_args, ctx) do
      case Context.ask(ctx,
             title: "登录 COROS",
             text: "用存有训练数据的账号登录",
             callback: true,
             url: fn callback ->
               "https://auth.example/authorize?redirect_uri=" <> URI.encode_www_form(callback)
             end
           ) do
        {:ok, %{"query" => %{"code" => code}}} -> {:ok, "code=" <> code}
        {:ok, answer} -> {:ok, "answered: " <> Jason.encode!(answer)}
        {:error, why} -> {:error, "no login: #{why}"}
      end
    end
  end

  defmodule AskingPipeline do
    use Longx.Agent.Pipeline
    plug Login
    plug Longx.Agent.Plugs.Request
  end

  test "a tool asks the person: a request on the thread with a callback URL; the browser's return answers it; an interrupt cancels it",
       %{bypass: bypass, dir: dir} do
    id = agent!("ask-#{System.unique_integer([:positive])}", dir, pipeline: AskingPipeline)

    route!(bypass, fn body ->
      # a fresh message asks for a login; the login's output ends the turn
      if List.last(body["input"])["type"] == "function_call_output",
        do: ResponsesFixture.assistant_message("logged in"),
        else: ResponsesFixture.function_call("login", nil, %{})
    end)

    {:ok, _} = Agent.send(id, "log me in")

    assert %{"requestId" => rid, "title" => "登录 COROS", "url" => url, "callbackUrl" => callback} =
             await("longx/action/request")

    assert callback =~ "/callback/" <> rid
    assert url =~ URI.encode_www_form(callback)

    assert [%{id: ^rid, method: "longx/action/request"}] =
             ThreadState.snapshot(id).pending_requests

    assert {:running, _} = Agent.status(id)

    # the browser came back through Longx: the query lands in the tool's hands
    assert :ok = Longx.Agent.Kernel.Asks.deliver(rid, %{"code" => "abc", "state" => "s"})
    assert %{"status" => "completed"} = await_turn_end()
    assert ThreadState.snapshot(id).pending_requests == []
    requests = collect_requests([])
    last = List.last(requests)

    assert Enum.any?(
             last["input"],
             &(&1["type"] == "function_call_output" and &1["output"] == "code=abc")
           )

    assert {:error, :unknown} = Longx.Agent.Kernel.Asks.deliver(rid, %{})

    # a second ask, cancelled by an interrupt: the request leaves the view with the turn
    {:ok, _} = Agent.send(id, "again")
    assert %{"requestId" => rid2} = await("longx/action/request")
    assert :ok = Agent.interrupt(id)
    assert %{"status" => "interrupted"} = await_turn_end()
    assert ThreadState.snapshot(id).pending_requests == []
    assert {:error, :unknown} = Agent.respond(id, rid2, %{"done" => true})
    Bypass.pass(bypass)
  end

  defmodule CompactingPipeline do
    use Longx.Agent.Pipeline
    plug Longx.Agent.Plugs.Shell
    # at 0.0: compacts as soon as any usage is known (the second step on)
    plug Longx.Agent.Plugs.Compaction, at: 0.0
    plug Longx.Agent.Plugs.Request
  end

  defp compacting_agent(dir, pipeline) do
    id = "compact-#{System.unique_integer([:positive])}"
    :ok = ThreadState.subscribe(id)

    on_exit(fn ->
      Agent.stop(id)
      ThreadState.stop(id)
      ThreadState.Store.delete(id)
    end)

    {:ok, _} = Agent.ensure(thread_id: id, cwd: dir, pipeline: pipeline)
    id
  end

  test "the compact effect: the context is folded into user messages + a summary before the next model call",
       %{bypass: bypass, dir: dir} do
    id = compacting_agent(dir, CompactingPipeline)

    script!(bypass, [
      exec_call("echo one"),
      ResponsesFixture.assistant_message("HANDOFF: ran echo one"),
      ResponsesFixture.assistant_message("done")
    ])

    {:ok, %{turn_id: turn_id}} = Agent.send(id, "run echo one, then say done")

    assert %{"item" => %{"type" => "contextCompaction"}} =
             await_item_completed_of_type("contextCompaction")

    assert %{"id" => ^turn_id, "status" => "completed"} = await_turn_end()

    [first, summary_request, third] = collect_requests([])
    assert length(first["input"]) == 1
    # the summary call: the whole context so far under the compaction instructions
    assert summary_request["instructions"] =~ "CONTEXT CHECKPOINT COMPACTION"
    assert Enum.any?(summary_request["input"], &(&1["type"] == "function_call"))
    assert summary_request["tools"] == []
    # the step after: the user's words verbatim, then the summary, nothing else
    assert [
             %{"role" => "user", "content" => [%{"text" => "run echo one, then say done"}]},
             %{"role" => "user", "content" => [%{"text" => prefixed}]}
           ] = third["input"]

    assert prefixed =~ "Another language model started to solve this problem"
    assert prefixed =~ "HANDOFF: ran echo one"

    kinds = Transcript.items!(id) |> Enum.map(& &1.kind)
    assert :compaction in kinds
    # a restart folds the same way
    assert [
             %{"role" => "user"},
             %{"role" => "user", "content" => [%{"text" => "Another" <> _}]},
             %{"role" => "assistant"}
           ] =
             Transcript.input(Transcript.items!(id))
  end

  defmodule DefaultCompaction do
    use Longx.Agent.Pipeline
    plug Longx.Agent.Plugs.Shell
    plug Longx.Agent.Plugs.Compaction
    plug Longx.Agent.Plugs.Request
  end

  test "a context-length error from the provider compacts and retries once", %{
    bypass: bypass,
    dir: dir
  } do
    id = compacting_agent(dir, DefaultCompaction)

    script!(bypass, [
      fn _body, conn ->
        Plug.Conn.send_resp(
          conn,
          400,
          ~s({"error":{"message":"This model's maximum context length is 8 tokens; your messages resulted in 9"}})
        )
      end,
      ResponsesFixture.assistant_message("HANDOFF"),
      ResponsesFixture.assistant_message("after")
    ])

    {:ok, %{turn_id: turn_id}} = Agent.send(id, "hello")
    assert %{"id" => ^turn_id, "status" => "completed"} = await_turn_end()
    assert [_, summary_request, _] = collect_requests([])
    assert summary_request["instructions"] =~ "CONTEXT CHECKPOINT"
  end

  test "a manual compact between turns folds the thread and the next turn starts from the summary",
       %{bypass: bypass, dir: dir} do
    id = compacting_agent(dir, DefaultCompaction)

    script!(bypass, [
      ResponsesFixture.assistant_message("first"),
      ResponsesFixture.assistant_message("HANDOFF"),
      ResponsesFixture.assistant_message("second")
    ])

    {:ok, _} = Agent.send(id, "one")
    await_turn_end()
    assert :ok = Agent.compact(id)

    # the page is told the fold is running (no turn carries it: `turnId` nil),
    # the summary's bytes as they come, and that it is over — a fold once showed
    # nothing for a minute and then the marker
    assert %{"turnId" => nil, "progress" => %{"kind" => "compaction", "bytes" => 0}} =
             await("turn/progress")

    assert %{"progress" => %{"kind" => "compaction", "bytes" => 7}} = await("turn/progress")

    assert %{"item" => %{"type" => "contextCompaction"}} =
             await_item_completed_of_type("contextCompaction")

    assert %{"progress" => nil} = await("turn/progress")
    assert Agent.status(id) == :idle

    {:ok, _} = Agent.send(id, "two")
    await_turn_end()
    [_, _, third] = collect_requests([])

    assert [
             %{"role" => "user", "content" => [%{"text" => "one"}]},
             %{"role" => "user", "content" => [%{"text" => "Another" <> _}]},
             %{"role" => "user", "content" => [%{"text" => "two"}]}
           ] = third["input"]
  end

  test "a manual compact whose model chain is spent leaves the agent alive and idle, the failure named (the tuple once crashed the process)",
       %{bypass: bypass, dir: dir} do
    id = compacting_agent(dir, DefaultCompaction)
    script!(bypass, [ResponsesFixture.assistant_message("first")])
    {:ok, _} = Agent.send(id, "one")
    await_turn_end()

    # every later call (the summary) fails for good: 503 through the retries, the chain spent
    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      Plug.Conn.send_resp(conn, 503, "down")
    end)

    assert :ok = Agent.compact(id)
    assert %{"progress" => %{"kind" => "compaction"}} = await("turn/progress")
    assert %{"progress" => nil} = await("turn/progress", 15_000)
    assert Agent.status(id) == :idle
    assert Enum.all?(ThreadState.snapshot(id).items, &(&1["type"] != "contextCompaction"))
    assert is_pid(Agent.whereis(id))
  end

  test "get_context_remaining answers from the step's usage; new_context_window asks for a compaction" do
    [remaining, fresh] =
      Enum.filter(
        Longx.Agent.Plugs.Compaction.__agent_tools__(),
        &(&1.name in ~w(get_context_remaining new_context_window))
      )
      |> Enum.sort_by(& &1.name)

    ctx = %Longx.Agent.Context{
      usage: %{last: %{"inputTokens" => 700, "outputTokens" => 100}, total: %{}},
      context_window: 1000
    }

    assert {:ok, text} = Longx.Agent.Tool.call(remaining, %{}, ctx)
    assert text =~ "200"
    assert {:ok, _, %{"compact" => true}} = Longx.Agent.Tool.call(fresh, %{}, ctx)
  end

  # a hosted search as OpenAI / 百炼 stream it: the call, then a message citing sources
  defp hosted_search_stream(query, url) do
    resp = %{id: "resp_ws", object: "response", created_at: 1, model: "fake-model", output: []}

    # 百炼's shape: several queries and the sources on the action; OpenAI adds url_citations
    ws = %{
      id: "ws_1",
      type: "web_search_call",
      status: "completed",
      action: %{
        type: "search",
        query: query,
        queries: [query, "second query"],
        sources: [%{type: "url", url: "https://example.org/a"}]
      }
    }

    msg_id = "msg_ws"

    message = %{
      id: msg_id,
      type: "message",
      status: "completed",
      role: "assistant",
      content: [
        %{
          type: "output_text",
          text: "found it",
          annotations: [
            %{type: "url_citation", url: url, title: "The page", start_index: 0, end_index: 8}
          ]
        }
      ]
    }

    [
      %{type: "response.created", response: Map.put(resp, :status, "in_progress")},
      %{type: "response.output_item.added", output_index: 0, item: %{ws | status: "in_progress"}},
      %{type: "response.output_item.done", output_index: 0, item: ws},
      %{
        type: "response.output_item.added",
        output_index: 1,
        item: %{message | content: [], status: "in_progress"}
      },
      %{
        type: "response.output_text.delta",
        item_id: msg_id,
        output_index: 1,
        content_index: 0,
        delta: "found it"
      },
      %{type: "response.output_item.done", output_index: 1, item: message},
      %{
        type: "response.completed",
        response:
          Map.merge(resp, %{
            status: "completed",
            output: [ws, message],
            usage: %{input_tokens: 3, output_tokens: 2, total_tokens: 5}
          })
      }
    ]
    |> Enum.with_index()
    |> Enum.map(fn {event, seq} ->
      "event: #{event.type}\ndata: #{Jason.encode!(Map.put(event, :sequence_number, seq))}\n\n"
    end)
  end

  # a hosted image generation as OpenAI streams it: the call with the picture, then a message
  defp image_generation_stream(png) do
    resp = %{id: "resp_ig", object: "response", created_at: 1, model: "fake-model", output: []}

    call = %{
      id: "ig_1",
      type: "image_generation_call",
      status: "completed",
      revised_prompt: "a red circle",
      output_format: "png",
      size: "1024x1024",
      result: Base.encode64(png)
    }

    message = %{
      id: "msg_ig",
      type: "message",
      status: "completed",
      role: "assistant",
      content: [%{type: "output_text", text: "here it is", annotations: []}]
    }

    [
      %{type: "response.created", response: Map.put(resp, :status, "in_progress")},
      %{
        type: "response.output_item.added",
        output_index: 0,
        item: %{call | status: "in_progress", result: nil}
      },
      %{type: "response.output_item.done", output_index: 0, item: call},
      %{
        type: "response.output_item.added",
        output_index: 1,
        item: %{message | content: [], status: "in_progress"}
      },
      %{
        type: "response.output_text.delta",
        item_id: "msg_ig",
        output_index: 1,
        content_index: 0,
        delta: "here it is"
      },
      %{type: "response.output_item.done", output_index: 1, item: message},
      %{
        type: "response.completed",
        response:
          Map.merge(resp, %{
            status: "completed",
            output: [call, message],
            usage: %{input_tokens: 3, output_tokens: 2, total_tokens: 5}
          })
      }
    ]
    |> Enum.with_index()
    |> Enum.map(fn {event, seq} ->
      "event: #{event.type}\ndata: #{Jason.encode!(Map.put(event, :sequence_number, seq))}\n\n"
    end)
  end

  test "hosted image generation: the model's picture is saved as an attachment, shown inline, and the context keeps a note instead of the bytes",
       %{bypass: bypass, thread_id: id, model: model} do
    AI.update_model!(model, %{image_generation: true})
    png = <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13>> <> :crypto.strong_rand_bytes(64)
    project_id = "proj-img-#{System.unique_integer([:positive])}"
    on_exit(fn -> Longx.Projects.Attachments.delete_all(project_id) end)

    script!(bypass, [
      image_generation_stream(png),
      ResponsesFixture.assistant_message("done")
    ])

    Agent.stop(id)
    Longx.Agent.Kernel.Specs.delete(id)

    {:ok, _} =
      Agent.ensure(thread_id: id, cwd: File.cwd!(), project_id: project_id, model: model.slug)

    {:ok, %{turn_id: turn_id}} = Agent.send(id, "draw a red circle")

    # the request offered the hosted tool
    assert_receive {:request, first}, 5_000

    assert [%{"type" => "image_generation"}] =
             Enum.filter(first["tools"], &(&1["type"] == "image_generation"))

    # the row: a send_file-shaped item the chat draws as an inline image, with the prompt as its title
    assert %{
             "item" => %{
               "type" => "dynamicToolCall",
               "namespace" => "longx",
               "tool" => "image_generation",
               "id" => row
             }
           } =
             await_item_started("dynamicToolCall")

    assert %{"item" => %{"id" => ^row, "status" => "completed", "details" => details}} =
             await_item_completed(row)

    assert %{
             "mime" => "image/png",
             "attachment" => true,
             "title" => "a red circle",
             "path" => name
           } = details

    assert String.ends_with?(name, ".png")
    assert File.read!(Path.join(Longx.Projects.Attachments.dir(project_id), name)) == png

    assert %{"id" => ^turn_id, "status" => "completed"} = await_turn_end()

    # the model's context: no base64, a note naming the file
    {:ok, _} = Agent.send(id, "and now?")
    assert_receive {:request, second}, 5_000
    refute inspect(second["input"]) =~ Base.encode64(png)

    assert Enum.any?(second["input"], fn item ->
             item["role"] == "user" and inspect(item["content"]) =~ name and
               inspect(item["content"]) =~ "image_generation"
           end)

    refute Enum.any?(second["input"], &(&1["type"] == "image_generation_call"))
    await_turn_end()
  end

  test "hosted web search: the provider's tool goes out, its call shows as a search row with the cited sources",
       %{bypass: bypass, thread_id: id, model: model} do
    provider = Ash.load!(model, :provider).provider
    AI.update_provider!(provider, %{supports_hosted_web_search: true})
    script!(bypass, [hosted_search_stream("elixir 1.19", "https://elixir-lang.org/blog")])

    {:ok, %{turn_id: turn_id}} = Agent.send(id, "what's new in elixir?")

    assert %{
             "item" => %{
               "type" => "webSearch",
               "id" => ws,
               "query" => "elixir 1.19 · second query",
               "action" => action
             }
           } = await_item_started("webSearch")

    assert %{"type" => "search"} = action
    refute Map.has_key?(action, "sources")

    # the action's sources are the row's results at once; a citation in the message adds to them
    assert %{
             "item" => %{
               "id" => ^ws,
               "status" => "completed",
               "results" => [%{"url" => "https://example.org/a"}]
             }
           } = await_item_completed(ws)

    assert %{"item" => %{"id" => ^ws, "results" => results}} = await_item_completed(ws)
    assert %{"url" => "https://elixir-lang.org/blog", "title" => "The page"} in results
    assert %{"url" => "https://example.org/a", "title" => "https://example.org/a"} in results
    assert %{"id" => ^turn_id, "status" => "completed"} = await_turn_end()
    assert_receive {:request, first}

    assert [%{"type" => "web_search", "external_web_access" => true}] =
             Enum.filter(first["tools"], &(&1["type"] == "web_search"))

    refute "web_search" in Enum.map(first["tools"], & &1["name"])
    assert "web_fetch" in Enum.map(first["tools"], & &1["name"])
    assert :hosted_call in Enum.map(Transcript.items!(id), & &1.kind)
  end

  test "the thread's search switch off mounts nothing; reading pages stays", %{
    bypass: bypass,
    dir: dir
  } do
    id = "nosearch-#{System.unique_integer([:positive])}"
    :ok = ThreadState.subscribe(id)

    on_exit(fn ->
      Agent.stop(id)
      ThreadState.stop(id)
      ThreadState.Store.delete(id)
    end)

    {:ok, _} = Agent.ensure(thread_id: id, cwd: dir, web_search: false)
    script!(bypass, [ResponsesFixture.assistant_message("quiet")])
    {:ok, _} = Agent.send(id, "hi")
    await_turn_end()
    assert_receive {:request, body}
    refute "web_search" in Enum.map(body["tools"], & &1["name"])
    refute Enum.any?(body["tools"], &(&1["type"] == "web_search"))
    assert "web_fetch" in Enum.map(body["tools"], & &1["name"])
  end

  # replies chosen per request body (a parent and its child share one Bypass)
  defp route!(bypass, fun) do
    test = self()

    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      {body, conn} = body!(conn)
      send(test, {:request, body})
      sse(conn, fun.(body))
    end)
  end

  # the gateway strips the client metadata, so a thread is known by its first words
  defp first_text(%{"input" => [%{"content" => [%{"text" => text} | _]} | _]}), do: text
  defp first_text(_body), do: nil

  defp last_text(%{"input" => input}) when is_list(input) do
    case List.last(input) do
      %{"content" => [%{"text" => text} | _]} -> text
      _ -> nil
    end
  end

  defp last_text(_body), do: nil

  defp agent!(id, dir, opts) do
    :ok = ThreadState.subscribe(id)

    on_exit(fn ->
      # the children first: one still streaming would write after the sandbox is gone
      if Agent.whereis(id), do: Enum.each(Agent.children(id), &Agent.stop(&1.id))
      Agent.stop(id)
      ThreadState.stop(id)
      ThreadState.Store.delete(id)
    end)

    {:ok, _} = Agent.ensure([thread_id: id, cwd: dir] ++ opts)
    id
  end

  test "an agent with a long transcript loads it in its own process: the supervisor's start_child returns at once, so another agent starts meanwhile; calls wait until it is loaded",
       %{dir: dir} do
    big = "big-#{System.unique_integer([:positive])}"
    small = "small-#{System.unique_integer([:positive])}"
    text = String.duplicate("x", 4_000)

    for seq <- 1..6_000 do
      Transcript.append!(%{
        thread_id: big,
        turn_id: "turn_old",
        seq: seq,
        kind: :agent_message,
        input: %{
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => text}]
        },
        ui: %{
          "id" => "item_#{seq}",
          "type" => "agentMessage",
          "turnId" => "turn_old",
          "text" => text
        }
      })
    end

    on_exit(fn ->
      for id <- [big, small] do
        Agent.stop(id)
        ThreadState.stop(id)
        ThreadState.Store.delete(id)
      end
    end)

    # the items are on disk (the writer's queue drained); what is measured is the load
    assert :ok = Transcript.flush()

    # the big one loads (a few hundred ms) while the small one starts: the
    # supervisor is not held up by the load, only the big one's caller waits
    loading = Task.async(fn -> :timer.tc(fn -> Agent.ensure(thread_id: big, cwd: dir) end) end)
    {other_us, {:ok, _}} = :timer.tc(fn -> Agent.ensure(thread_id: small, cwd: dir) end)
    {ensure_us, {:ok, pid}} = Task.await(loading, 30_000)
    # a start queued behind the load took as long as the load itself; a
    # loaded suite makes an absolute bound flaky, the ratio holds either way
    assert other_us * 5 < ensure_us
    assert other_us < 100_000
    assert Process.alive?(pid)
    # ensure answers with the transcript loaded: the view is there, a call answers at once
    assert length(ThreadState.snapshot(big).items) == 6_000
    {status_us, :idle} = :timer.tc(fn -> Agent.status(big) end)
    assert status_us < 100_000
  end

  defmodule Counting do
    use Longx.Agent.Plug

    # step.state lives for the turn: the plug counts its steps and stops at three
    def call(%Step{phase: :turn_end} = step, _) do
      rounds = Map.get(step.state, :rounds, 0) + 1
      step = Step.put_state(step, :rounds, rounds)
      if rounds < 3, do: Step.continue(step, "round #{rounds + 1}"), else: step
    end

    def call(step, _), do: step
  end

  defmodule CountingPipeline do
    use Longx.Agent.Pipeline
    plug Counting
    plug Longx.Agent.Plugs.Request
  end

  test "step.state survives across the phases and steps of a turn", %{bypass: bypass, dir: dir} do
    id = agent!("state-#{System.unique_integer([:positive])}", dir, pipeline: CountingPipeline)
    script!(bypass, List.duplicate(ResponsesFixture.assistant_message("ok"), 5))
    {:ok, %{turn_id: turn_id}} = Agent.send(id, "go")
    assert %{"id" => ^turn_id, "status" => "completed"} = await_turn_end()
    assert length(collect_requests([])) == 3
  end

  test "a child agent is another process: its answer lands in the parent's mailbox and wakes it",
       %{bypass: bypass, dir: dir} do
    parent = agent!("parent-#{System.unique_integer([:positive])}", dir, name: "main")

    route!(bypass, fn body ->
      case {first_text(body), body["input"]} do
        {"start", [_]} -> ResponsesFixture.assistant_message("delegated")
        {"start", _} -> ResponsesFixture.assistant_message("thanks, child")
        _ -> ResponsesFixture.assistant_message("CHILD REPORT: 42")
      end
    end)

    {:ok, _} = Agent.send(parent, "start")
    await("turn/started")
    assert %{"status" => "completed"} = await_turn_end()

    # spawn from outside a turn (a tool or a strategy would do this from inside one)
    assert {:ok, child} = Agent.spawn(parent, "researcher", "find the answer", model: nil)
    assert Agent.whereis(child)
    assert %{parent: ^parent, name: "researcher"} = Agent.info(child)
    assert [%{id: ^child, name: "researcher"}] = Agent.children(parent)

    # the parent's view shows the child the way codex does: a subAgentActivity item (the
    # client folds it into a subagent row whose body is the child's own conversation)
    assert %{
             "item" => %{
               "type" => "subAgentActivity",
               "agentThreadId" => ^child,
               "agentPath" => "/root/researcher",
               "kind" => "started"
             }
           } = await_item_completed_of_type("subAgentActivity")

    # the child's final message wakes the idle parent: a new turn whose input is the report, attributed
    assert %{"turn" => %{"id" => woke}} = await("turn/started")

    assert %{
             "item" => %{
               "type" => "subAgentActivity",
               "agentThreadId" => ^child,
               "kind" => "completed"
             },
             "turnId" => ^woke
           } = await_item_completed_of_type("subAgentActivity")

    # the item says what it is: a report of the task, not a question or an answer
    assert %{"turnId" => ^woke, "from" => "researcher", "kind" => "report"} =
             await_user_message("[agent researcher] CHILD REPORT: 42")

    assert %{"id" => ^woke, "status" => "completed"} = await_turn_end()
    # the activities survive a rebuild of the view from the transcript
    assert 2 ==
             Enum.count(ThreadState.snapshot(parent).items, &(&1["type"] == "subAgentActivity"))

    requests = collect_requests([])
    child_request = Enum.find(requests, &(first_text(&1) == "find the answer"))

    assert [%{"role" => "user", "content" => [%{"text" => "find the answer"}]}] =
             child_request["input"]

    # codex's subagent role text (models.json multi_agent.role.subagent), adapted
    assert child_request["instructions"] =~
             "You are an agent in a team of agents collaborating to complete a task."

    assert child_request["instructions"] =~
             "your final answer may be read by a human, so ensure it is legible"

    # codex's canonical task name: the child's identity is a path whose parent is its parent
    # (a coder-3 once took the sibling `coder` for the main agent)
    assert child_request["instructions"] =~ "your identity is `/root/researcher`"
    assert child_request["instructions"] =~ "(`/root`) is your parent"
    assert child_request["instructions"] =~ "delivered back to your parent agent"

    # a task cannot override the role's own rules: the child is told which wins
    assert child_request["instructions"] =~ "take precedence over the task"
    parent_last = requests |> Enum.filter(&(first_text(&1) == "start")) |> List.last()

    assert List.last(parent_last["input"])["content"] |> hd() |> Map.get("text") =~
             "[agent researcher] CHILD REPORT: 42"
  end

  test "a child crashing mid-turn is restarted by its guard: the view's turn is settled, the parent hears it restarted, the member stays (the crash once left the child 'working' for ever)",
       %{bypass: bypass, dir: dir} do
    parent = agent!("parent-#{System.unique_integer([:positive])}", dir, name: "main")
    # the child's one call is held (its turn stays in flight); the parent's, once told, answers
    script!(bypass, [
      held(ResponsesFixture.assistant_message("never")),
      ResponsesFixture.assistant_message("fine")
    ])

    {:ok, child} = Agent.spawn(parent, "helper", "hold on", model: nil)
    :ok = ThreadState.subscribe(child)
    assert_receive {:held, _handler}, 5_000
    # the child's turn began before the subscription: the view says it is in flight
    assert %{"id" => turn_id, "status" => "inProgress"} = ThreadState.snapshot(child).turn

    old_pid = Agent.whereis(child)
    Process.exit(old_pid, :kill)
    new_pid = await_restart(child, old_pid)
    assert Process.alive?(new_pid)

    # the restarted process settles the turn it found in flight in the view…
    assert %{
             "turn" => %{
               "id" => ^turn_id,
               "status" => "failed",
               "error" => %{"message" => message}
             }
           } =
             await_on(child, "turn/completed")

    assert message =~ "crash"
    assert Agent.status(child) == :idle
    # …and tells its parent, which decides what to do (the task was not finished)
    assert %{"turn" => %{"id" => woke}} = await_on(parent, "turn/started")

    assert %{"turnId" => ^woke} =
             await_user_message_matching(~r/\[agent helper\] restarted after a crash mid-turn/)

    await_on(parent, "turn/completed")
    assert [%{id: ^child, name: "helper", status: "done"}] = Agent.children(parent)
    Bypass.pass(bypass)
  end

  # a plain "interrupted: no details" once read as an environment failure and the parent restarted the task
  test "a child stopped by the person: the parent is told who stopped it and that the task is unfinished, the row says interrupted, the member is stopped",
       %{bypass: bypass, dir: dir} do
    parent = agent!("parent-#{System.unique_integer([:positive])}", dir, name: "main")

    script!(bypass, [
      held(ResponsesFixture.assistant_message("never")),
      ResponsesFixture.assistant_message("noted")
    ])

    {:ok, child} = Agent.spawn(parent, "helper", "hold on", model: nil)
    :ok = ThreadState.subscribe(child)
    assert_receive {:held, _handler}, 5_000
    drain_activities()

    assert :ok = Agent.interrupt(child, by: :person)
    Bypass.pass(bypass)

    assert %{"turn" => %{"status" => "interrupted", "error" => %{"message" => reason}}} =
             await_on(child, "turn/completed")

    assert reason =~ "stopped by the person"

    assert %{"turn" => %{"id" => woke}} = await_on(parent, "turn/started")

    assert %{
             "item" => %{
               "type" => "subAgentActivity",
               "kind" => "interrupted",
               "agentThreadId" => ^child
             }
           } =
             await_item_completed_of_type("subAgentActivity")

    assert %{"turnId" => ^woke} =
             await_user_message_matching(
               ~r/\[agent helper\] stopped by the person from the page; the task is not finished — do not start it again unless asked/
             )

    await_on(parent, "turn/completed")
    assert [%{id: ^child, name: "helper", status: "stopped"}] = Agent.children(parent)
  end

  test "a child crashing past its guard's budget is gone for good: the parent hears it exited, the member is failed",
       %{bypass: bypass, dir: dir} do
    parent = agent!("parent-#{System.unique_integer([:positive])}", dir, name: "main")
    route!(bypass, fn _body -> ResponsesFixture.assistant_message("fine") end)
    {:ok, child} = Agent.spawn(parent, "helper", "hold on", model: nil)
    await_on(parent, "turn/started")
    await_on(parent, "turn/completed")
    drain_activities()

    # three restarts in a minute is the budget; the fourth crash ends the guard
    Enum.reduce(1..3, Agent.whereis(child), fn _, pid ->
      Process.exit(pid, :kill)
      await_restart(child, pid)
    end)

    Process.exit(Agent.whereis(child), :kill)
    assert %{"turn" => %{"id" => woke}} = await_on(parent, "turn/started")

    assert %{"turnId" => ^woke} =
             await_user_message_matching(~r/\[agent helper\] exited:.*restart/s)

    await_on(parent, "turn/completed")
    assert [%{id: ^child, name: "helper", status: "failed"}] = Agent.children(parent)
    assert Agent.whereis(child) == nil
    assert Longx.Agent.Guard.whereis(child) == nil
  end

  # the idle exit ends the agent first and its guard a moment later
  # (auto_shutdown): an ensure in between met the old guard, waited a second
  # for an agent it would never start again and answered :not_started — a
  # slow CI runner made the moment long enough to hit
  test "an agent asked for while its guard still winds down after the idle exit comes back under a fresh guard",
       %{dir: dir} do
    id = agent!("wind-#{System.unique_integer([:positive])}", dir, idle_ms: 100)
    guard = Longx.Agent.Guard.whereis(id)
    pid = Agent.whereis(id)
    # the guard held before it acts on the exit: the agent gone, the guard still there
    :sys.suspend(guard)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    assert Process.alive?(guard)

    task = Task.async(fn -> Agent.ensure_alive(id) end)
    # the ask has met the old guard and waits
    await_sleeping(task.pid)
    guard_ref = Process.monitor(guard)
    :sys.resume(guard)
    assert_receive {:DOWN, ^guard_ref, :process, ^guard, _}, 5_000

    assert {:ok, new_pid} = Task.await(task, 10_000)
    assert new_pid != pid and Process.alive?(new_pid)
    assert Longx.Agent.Guard.whereis(id) not in [nil, guard]
  end

  defp await_sleeping(pid, tries \\ 500) do
    case Process.info(pid, :current_function) do
      {:current_function, {Process, :sleep, 1}} ->
        :ok

      _ when tries > 0 ->
        receive do
        after
          5 -> :ok
        end

        await_sleeping(pid, tries - 1)
    end
  end

  # the agent back under a new pid after a crash (its guard restarts it at once)
  defp await_restart(thread_id, old_pid, tries \\ 100) do
    case Agent.whereis(thread_id) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _ when tries > 0 ->
        Process.sleep(20)
        await_restart(thread_id, old_pid, tries - 1)

      _ ->
        flunk("#{thread_id} did not come back")
    end
  end

  test "a parent can talk to its child; a killed idle child comes back on its own; a stopped parent takes its children along",
       %{bypass: bypass, dir: dir} do
    parent = agent!("parent-#{System.unique_integer([:positive])}", dir, name: "main")
    route!(bypass, fn _body -> ResponsesFixture.assistant_message("fine") end)

    {:ok, child} = Agent.spawn(parent, "helper", "hold on", model: nil)
    # the child's report wakes the parent once
    await("turn/started")
    await_turn_end()

    :ok = ThreadState.subscribe(child)
    assert {:ok, %{steered: false}} = Agent.send(child, "more", from: "main")
    assert %{"from" => "main"} = await_user_message("[agent main] more")
    # ... and its second report wakes the parent again (both threads are subscribed now)
    await_on(parent, "turn/started")
    await_on(parent, "turn/completed")
    drain_activities()

    # an idle child killed comes back under its guard on its own — nothing was
    # lost, nobody is told; the member stays
    old_pid = Agent.whereis(child)
    Process.exit(old_pid, :kill)
    new_pid = await_restart(child, old_pid)
    assert Process.alive?(new_pid)
    refute_receive {:thread, _, "turn/started", %{"threadId" => ^parent}}, 500
    assert [%{id: ^child, name: "helper", status: "done"}] = Agent.children(parent)

    {:ok, child2} = Agent.spawn(parent, "helper2", "wait", model: nil)
    pid = Agent.whereis(child2)
    ref = Process.monitor(pid)
    :ok = Agent.stop(parent)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
  end

  test "a finished child stays in the team: a follow-up continues its transcript, it comes back after an idle exit, the team survives the parent leaving; close removes it",
       %{bypass: bypass, dir: dir} do
    parent = agent!("keep-#{System.unique_integer([:positive])}", dir, name: "main", idle_ms: 200)

    route!(bypass, fn body ->
      case last_text(body) do
        "task one" -> ResponsesFixture.assistant_message("ANSWER ONE")
        "[agent main] and then?" -> ResponsesFixture.assistant_message("MORE")
        _ -> ResponsesFixture.assistant_message("ok")
      end
    end)

    {:ok, child} = Agent.spawn(parent, "helper", "task one", model: nil, role: "helper")
    # the report wakes the parent; the child is done, not gone
    await("turn/started")
    await_turn_end()

    assert [%{id: ^child, name: "helper", status: "done", role: "helper", task: "task one"}] =
             Agent.children(parent)

    # the child leaves idle (it inherits idle_ms) and is still a member
    await_gone(child)
    assert [%{status: "done"}] = Agent.children(parent)

    # a follow-up: the child is back with its whole transcript; its answer comes to the asker
    :ok = ThreadState.subscribe(child)
    drain_activities()

    assert {:ok, %{steered: false}} =
             Agent.send(child, "and then?", from: "main", reply_to: parent)

    assert %{"turn" => %{"id" => woke}} = await_on(parent, "turn/started")
    assert %{"turnId" => ^woke, "from" => "helper"} = await_user_message("[agent helper] MORE")
    await_on(parent, "turn/completed")

    follow_up =
      collect_requests([])
      |> Enum.find(&(first_text(&1) == "task one" and length(&1["input"]) > 1))

    texts = for %{"content" => c} <- follow_up["input"], %{"text" => t} <- c, do: t
    assert "task one" in texts
    assert "ANSWER ONE" in texts
    assert "[agent main] and then?" in texts

    # the parent leaves idle too and forgets nothing: the team is rebuilt from the specs
    await_gone(parent)
    assert {:ok, _} = Agent.ensure_alive(parent)

    assert [%{id: ^child, name: "helper", status: "done", task: "task one"}] =
             Agent.children(parent)

    # closed: gone from the team
    :ok = Agent.forget_child(parent, child)
    Agent.stop(child)
    assert Agent.children(parent) == []
  end

  test "teammates: a child asks a sibling and the answer comes back to the asker; the parent's team lists both as done",
       %{bypass: bypass, dir: dir} do
    parent = agent!("sib-#{System.unique_integer([:positive])}", dir, name: "main")

    route!(bypass, fn body ->
      case last_text(body) do
        "[agent alpha] what did you find?" -> ResponsesFixture.assistant_message("BETA SAYS 7")
        _ -> ResponsesFixture.assistant_message("done")
      end
    end)

    {:ok, alpha} = Agent.spawn(parent, "alpha", "a", model: nil)
    await("turn/started")
    await_turn_end()
    {:ok, beta} = Agent.spawn(parent, "beta", "b", model: nil)
    await("turn/started")
    await_turn_end()

    assert [%{name: "alpha", status: "done"}, %{name: "beta", status: "done"}] =
             Agent.children(parent)

    :ok = ThreadState.subscribe(alpha)
    :ok = ThreadState.subscribe(beta)
    drain_activities()
    assert {:ok, _} = Agent.send(beta, "what did you find?", from: "alpha", reply_to: alpha)
    # a message that expects an answer (reply_to) is a question on beta's page
    assert %{"from" => "alpha", "kind" => "question"} =
             await_user_message("[agent alpha] what did you find?")

    # beta's answer is a message in alpha's mailbox, not the parent's — and says it answers
    assert %{"turn" => %{"id" => t}} = await_on(alpha, "turn/started")

    assert %{"turnId" => ^t, "from" => "beta", "kind" => "answer"} =
             await_user_message("[agent beta] BETA SAYS 7")

    assert %{"turn" => %{"id" => ^t}} = await_on(alpha, "turn/completed")
    # ... and alpha's answer to it goes to its parent, as any of its reports
    await_on(parent, "turn/started")
    await_on(parent, "turn/completed")
  end

  test "an idle agent leaves after idle_ms and comes back on demand from its transcript", %{
    bypass: bypass,
    dir: dir
  } do
    id = agent!("idle-#{System.unique_integer([:positive])}", dir, idle_ms: 150)

    script!(bypass, [
      ResponsesFixture.assistant_message("one"),
      ResponsesFixture.assistant_message("two")
    ])

    {:ok, _} = Agent.send(id, "hi")
    await_turn_end()

    pid = Agent.whereis(id)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    assert Agent.whereis(id) == nil

    # the same spec, the same history
    assert {:ok, _} = Agent.ensure_alive(id)
    assert Agent.whereis(id)
    {:ok, _} = Agent.send(id, "again")
    await_turn_end()
    assert_receive {:request, _}
    assert_receive {:request, body}
    assert length(body["input"]) == 3
  end

  defmodule Delegating do
    use Longx.Agent.Plug

    # a strategy: a turn end with no worker yet sends one out; its report comes back as
    # a turn (the worker inherits this pipeline: at depth 1 it delegates to nobody)
    def call(%Step{phase: :turn_end} = step, _) do
      if step.assigns.depth > 0 or Enum.any?(step.assigns.children, &(&1.name == "worker")),
        do: step,
        else: Step.spawn(step, "worker", "do the work")
    end

    def call(step, _), do: step
  end

  defmodule DelegatingPipeline do
    use Longx.Agent.Pipeline
    plug Delegating
    plug Longx.Agent.Plugs.Request
  end

  test "a plug spawns a child through the spawn effect", %{bypass: bypass, dir: dir} do
    parent =
      agent!("deleg-#{System.unique_integer([:positive])}", dir, pipeline: DelegatingPipeline)

    route!(bypass, fn body ->
      case first_text(body) do
        "do the work" -> ResponsesFixture.assistant_message("WORK DONE")
        _ -> ResponsesFixture.assistant_message("ok")
      end
    end)

    {:ok, %{turn_id: first}} = Agent.send(parent, "go")
    await("turn/started")
    assert %{"id" => ^first, "status" => "completed"} = await_turn_end()
    assert [%{name: "worker"}] = Agent.children(parent)

    assert %{"turn" => %{"id" => woke}} = await("turn/started")

    assert %{"turnId" => ^woke, "from" => "worker"} =
             await_user_message("[agent worker] WORK DONE")

    assert %{"id" => ^woke, "status" => "completed"} = await_turn_end()
    # the second turn saw its child and sent nobody else
    assert [%{name: "worker"}] = Agent.children(parent)
  end

  test "the kernel names children uniquely and refuses a spawn past the depth limit", %{
    bypass: bypass,
    dir: dir
  } do
    parent =
      agent!("deep-#{System.unique_integer([:positive])}", dir,
        pipeline: EffectsPipeline,
        depth: 2
      )

    route!(bypass, fn _body -> ResponsesFixture.assistant_message("fine") end)
    assert {:error, :too_deep} = Agent.spawn(parent, "helper", "x", model: nil)

    shallow =
      agent!("shallow-#{System.unique_integer([:positive])}", dir, pipeline: EffectsPipeline)

    assert {:ok, a} = Agent.spawn(shallow, "helper", "x", model: nil)
    assert {:ok, b} = Agent.spawn(shallow, "helper", "y", model: nil)
    assert a != b

    assert ["helper", "helper-2"] =
             shallow |> Agent.children() |> Enum.map(& &1.name) |> Enum.sort()

    assert %{name: "helper-2"} = Agent.info(b)
    # the children may not have reached the model before the test ends
    Bypass.pass(bypass)
  end

  test "the Agents plug: send_message asks a finished agent again on its kept context; the parent sees the exchange",
       %{bypass: bypass, dir: dir} do
    File.mkdir_p!(Path.join(dir, ".longx/local/agents/researcher"))

    File.write!(
      Path.join(dir, ".longx/local/agents/researcher/agent.exs"),
      "import Longx.Agent.Config\nagent do\n  summary \"looks things up\"\n  prompt \"Role: researcher\"\n  agents []\nend\n"
    )

    parent = agent!("again-#{System.unique_integer([:positive])}", dir, trust: fn -> true end)

    route!(bypass, fn body ->
      case last_text(body) do
        "go" ->
          ResponsesFixture.function_call("spawn_agent", nil, %{
            "agent" => "researcher",
            "task" => "find X"
          })

        "find X" ->
          ResponsesFixture.assistant_message("REPORT X")

        "[agent researcher] REPORT X" ->
          ResponsesFixture.function_call("send_message", nil, %{
            "agent" => "researcher",
            "message" => "which source?"
          })

        "[agent main] which source?" ->
          ResponsesFixture.assistant_message("SOURCE Y")

        "[agent researcher] SOURCE Y" ->
          ResponsesFixture.assistant_message("thanks")

        _ ->
          ResponsesFixture.assistant_message("ok")
      end
    end)

    {:ok, _} = Agent.send(parent, "go")
    # the report comes back (a steer while the parent still works, a turn of
    # its own otherwise — Bypass answers fast), the parent asks again, the
    # follow-up's answer comes back the same way
    assert %{"from" => "researcher"} = await_user_message("[agent researcher] REPORT X")
    assert %{"from" => "researcher"} = await_user_message("[agent researcher] SOURCE Y")
    await_idle(parent)

    assert [%{name: "researcher", status: "done", task: "find X"}] = Agent.children(parent)

    requests = collect_requests([])
    follow_up = Enum.find(requests, &(last_text(&1) == "[agent main] which source?"))
    texts = for %{"content" => c} <- follow_up["input"], %{"text" => t} <- c, do: t
    assert "find X" in texts and "REPORT X" in texts

    # the parent's team listing named the finished agent, and the send_message tool offered it
    asked = Enum.find(requests, &(last_text(&1) == "[agent researcher] REPORT X"))
    assert asked["instructions"] =~ "researcher (researcher, done): find X"
    tool = Enum.find(asked["tools"], &(&1["name"] == "send_message"))
    assert tool["parameters"]["properties"]["agent"]["enum"] == ["researcher"]

    kinds =
      ThreadState.snapshot(parent).items
      |> Enum.filter(&(&1["type"] == "subAgentActivity"))
      |> Enum.map(& &1["kind"])

    assert kinds == ["started", "completed", "interacted", "completed"]
  end

  test "the shipped Agents plug: spawn_agent starts a declared role on its own description, the report comes back",
       %{bypass: bypass, dir: dir} do
    test = self()
    File.mkdir_p!(Path.join(dir, ".longx/local/agents/researcher"))

    File.write!(
      Path.join(dir, ".longx/agent.exs"),
      "import Longx.Agent.Config\nagent do\n  prompt \"Project Q.\"\nend\n"
    )

    # the project's own role (Longx ships none): a local declaration with its prompt
    File.write!(
      Path.join(dir, ".longx/local/agents/researcher/agent.exs"),
      "import Longx.Agent.Config\nagent do\n  summary \"looks things up\"\n  prompt_file \"prompt.md\"\n  drop Longx.Agent.Plugs.Patch\n  agents []\nend\n"
    )

    File.write!(
      Path.join(dir, ".longx/local/agents/researcher/prompt.md"),
      "# Role: researcher\n"
    )

    parent = agent!("team-#{System.unique_integer([:positive])}", dir, trust: fn -> true end)

    route!(bypass, fn body ->
      case {first_text(body), length(body["input"])} do
        {"go", 1} ->
          ResponsesFixture.function_call("spawn_agent", nil, %{
            "agent" => "researcher",
            "task" => "find X"
          })

        {"go", _} ->
          ResponsesFixture.assistant_message("delegated")

        _ ->
          # the child's answer waits until the parent's turn is over: the report then wakes it
          send(test, {:held, self()})

          receive do
            :go -> ResponsesFixture.assistant_message("REPORT X")
          end
      end
    end)

    {:ok, _} = Agent.send(parent, "go")
    await("turn/started")
    assert %{"status" => "completed"} = await_turn_end()
    assert [%{name: "researcher"}] = Agent.children(parent)
    assert_receive {:held, handler}, 5_000
    send(handler, :go)

    assert %{"turn" => %{"id" => woke}} = await("turn/started")

    assert %{"turnId" => ^woke, "from" => "researcher"} =
             await_user_message("[agent researcher] REPORT X")

    await_turn_end()

    requests = collect_requests([])
    first = Enum.find(requests, &(first_text(&1) == "go"))
    spawn_tool = Enum.find(first["tools"], &(&1["name"] == "spawn_agent"))
    assert ["researcher"] == spawn_tool["parameters"]["properties"]["agent"]["enum"]

    child = Enum.find(requests, &(first_text(&1) == "find X"))

    # the role's prompt on top of the project's; the role has no apply_patch, no spawning of its own
    assert child["instructions"] =~ "Role: researcher"
    assert child["instructions"] =~ "Project Q."
    assert child["instructions"] =~ "sub-agent"
    names = Enum.map(child["tools"], & &1["name"])
    refute "apply_patch" in names
    refute "spawn_agent" in names
    assert "exec_command" in names

    # the model was told the spawn worked and that the report arrives on its own
    second = Enum.find(requests, &(first_text(&1) == "go" and length(&1["input"]) > 1))

    output =
      second["input"] |> Enum.find(&(&1["type"] == "function_call_output")) |> Map.get("output")

    assert output =~ "researcher"
    assert output =~ "report"
  end

  test "the goal tools answer as codex's do: the goal as JSON, remaining tokens, a report to make on completion",
       %{thread_id: thread_id} do
    alias Longx.Agent.Plugs.Goal
    ctx = %{thread_id: thread_id}

    assert {:ok, none} = Goal.get_goal(%{}, ctx)
    assert %{"goal" => nil} = Jason.decode!(none)

    assert {:ok, made} =
             Goal.create_goal(%{"objective" => " ship it ", "token_budget" => 500}, ctx)

    assert %{
             "goal" => %{"objective" => "ship it", "status" => "active", "tokenBudget" => 500},
             "remainingTokens" => 500
           } = Jason.decode!(made)

    assert {:error, "cannot create a new goal" <> _} =
             Goal.create_goal(%{"objective" => "another"}, ctx)

    assert {:ok, done} = Goal.update_goal(%{"status" => "complete"}, ctx)

    assert %{
             "goal" => %{"status" => "complete"},
             "completionBudgetReport" => "Goal achieved." <> _
           } =
             Jason.decode!(done)

    # complete: a new goal may replace it
    assert {:ok, _} = Goal.create_goal(%{"objective" => "next"}, ctx)
  end

  test "goal mode: create_goal keeps the turn going with continuation steps until the model marks it complete; the goal is shown and survives a restart",
       %{bypass: bypass, dir: dir} do
    id = agent!("goal-#{System.unique_integer([:positive])}", dir, [])

    route!(bypass, fn body ->
      last = List.last(body["input"])

      cond do
        length(body["input"]) == 1 ->
          ResponsesFixture.function_call("create_goal", nil, %{"objective" => "make it green"})

        last["type"] == "function_call_output" and last["output"] =~ ~s("status":"active") ->
          ResponsesFixture.assistant_message("started")

        last["type"] == "message" and
            hd(last["content"])["text"] =~ "Continue working toward the active thread goal" ->
          ResponsesFixture.function_call("update_goal", nil, %{"status" => "complete"})

        true ->
          ResponsesFixture.assistant_message("done")
      end
    end)

    {:ok, %{turn_id: turn_id}} = Agent.send(id, "go")

    assert %{"goal" => %{"objective" => "make it green", "status" => "active"}} =
             await("thread/goal/updated")

    # every model call charges the goal and the page hears of it at once — the
    # bar once read 0 · 0 秒 for a whole goal and jumped to 1.7M · 12 min at its end
    assert %{"goal" => %{"status" => "active", "tokensUsed" => 17, "timeUsedSeconds" => t}} =
             await("thread/goal/updated")

    assert is_integer(t)

    assert %{"goal" => %{"status" => "complete", "tokensUsed" => 32}} =
             await_goal_status("complete")

    assert %{"id" => ^turn_id, "status" => "completed"} = await_turn_end()

    requests = collect_requests([])
    # one continuation step carried the objective; nothing more once complete
    continuations =
      Enum.filter(requests, fn r ->
        Enum.any?(
          r["input"],
          &(&1["type"] == "message" and &1["role"] == "user" and
              hd(&1["content"])["text"] =~ "make it green")
        )
      end)

    assert length(continuations) >= 1

    assert %{"objective" => "make it green", "status" => "complete"} =
             ThreadState.snapshot(id).goal

    assert {:ok, %{"status" => "complete"}} = Agent.get_goal(id)

    # a new process reads the goal back from the view
    Agent.stop(id)
    {:ok, _} = Agent.ensure_alive(id)
    assert {:ok, %{"objective" => "make it green"}} = Agent.get_goal(id)
    assert {:ok, true} = Agent.clear_goal(id)
    assert %{} = await("thread/goal/cleared")
    assert ThreadState.snapshot(id).goal == nil
  end

  test "a goal set by hand on an idle agent starts a turn by itself — codex: an active goal starts an idle turn — and a paused one waits",
       %{bypass: bypass, dir: dir} do
    id = agent!("goalstart-#{System.unique_integer([:positive])}", dir, [])

    route!(bypass, fn body ->
      last = List.last(body["input"])

      if last["type"] == "message" and
           hd(last["content"])["text"] =~ "Continue working toward the active thread goal",
         do: ResponsesFixture.function_call("update_goal", nil, %{"status" => "complete"}),
         else: ResponsesFixture.assistant_message("done")
    end)

    # paused: shown, nothing runs (the person set it aside; a goal once set from
    # the page sat idle until a child's report happened to wake the thread)
    assert {:ok, %{"status" => "paused"}} =
             Agent.set_goal(id, %{"objective" => "make it green", "status" => "paused"})

    assert %{"goal" => %{"status" => "paused"}} = await("thread/goal/updated")
    refute_receive {:thread, _, "turn/started", _}, 300

    # active: a turn of its own, the continuation as its words, marked as the kernel's
    assert {:ok, %{"status" => "active"}} = Agent.set_goal(id, %{"status" => "active"})
    assert %{"turn" => %{"id" => turn_id}} = await("turn/started")

    assert %{"origin" => %{"kind" => "goal", "round" => 1}, "content" => [%{"text" => text}]} =
             await_user_message_matching(~r/Continue working toward the active thread goal/)

    assert text =~ "make it green"
    assert %{"goal" => %{"status" => "complete"}} = await_goal_status("complete")
    assert %{"id" => ^turn_id, "status" => "completed"} = await_turn_end()
    # the round the started turn used is not spent again by the turn's end
    assert 1 ==
             Enum.count(
               ThreadState.snapshot(id).items,
               &(get_in(&1, ["origin", "kind"]) == "goal")
             )
  end

  defmodule Budget do
    use Longx.Agent.Plug
    def call(step, _), do: Step.halt(step, "budget spent")
  end

  defmodule HaltingPipeline do
    use Longx.Agent.Pipeline
    plug Budget
    plug Longx.Agent.Plugs.Request
  end

  test "a halted pipeline ends the turn without calling the model", %{dir: dir} do
    id = "halting-#{System.unique_integer([:positive])}"
    :ok = ThreadState.subscribe(id)

    on_exit(fn ->
      Agent.stop(id)
      ThreadState.stop(id)
      ThreadState.Store.delete(id)
    end)

    {:ok, _} = Agent.ensure(thread_id: id, cwd: dir, pipeline: HaltingPipeline)

    {:ok, %{turn_id: turn_id}} = Agent.send(id, "hi")

    assert %{"id" => ^turn_id, "status" => "failed", "error" => %{"message" => message}} =
             await_turn_end()

    assert message =~ "budget spent"
    refute_receive {:request, _}, 100
  end

  test "the model and level of a send are used for the request", %{
    bypass: bypass,
    thread_id: id,
    model: model
  } do
    script!(bypass, [ResponsesFixture.assistant_message("ok")])
    {:ok, _} = Agent.send(id, "hi", model: model.slug, effort: "high")
    await_turn_end()
    assert_receive {:request, body}
    assert body["reasoning"] == %{"effort" => "high", "summary" => "auto"}
    assert [_, %{model: slug}] = Transcript.items!(id)
    assert slug == model.slug
  end

  test "a child inherits the session's model and level unless its role names its own; the turn says what it runs on",
       %{bypass: bypass, dir: dir, model: model} do
    # a second model, the session's pick; the default stays `model`
    other =
      AI.create_model!(%{
        name: "Other",
        upstream_id: "real-other",
        slug: "other-#{System.unique_integer([:positive])}",
        provider_id: model.provider_id,
        reasoning_levels: ["low", "high"],
        context_window: 64_000
      })

    File.mkdir_p!(Path.join(dir, ".longx/local/agents/picky"))

    File.write!(
      Path.join(dir, ".longx/local/agents/picky/agent.exs"),
      "import Longx.Agent.Config\nagent do\n  model #{inspect(model.slug)}, effort: \"high\"\n  prompt \"be picky\"\nend\n"
    )

    id =
      agent!("inherit-#{System.unique_integer([:positive])}", dir,
        models: &Longx.AI.model_choices/0
      )

    # every request (the children's reports wake the parent too) gets the same
    # short answer: only the requests' bodies matter here
    test = self()

    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      {body, conn} = body!(conn)
      send(test, {:request, body})
      sse(conn, ResponsesFixture.assistant_message("ok"))
    end)

    {:ok, _} = Agent.send(id, "go", model: other.slug, effort: "low")
    assert_receive {:request, parent_body}, 5_000
    assert parent_body["model"] == "real-other"
    # the turn says what it runs on: the slug and the level in force
    assert_receive {:thread, _, "turn/model", %{"model" => slug, "effort" => "low"}}, 5_000
    assert slug == other.slug
    assert %{"status" => "completed"} = await_turn_end()
    # the prompt tells the agent too
    assert parent_body["instructions"] =~ "<model>#{other.slug}"
    assert parent_body["instructions"] =~ "reasoning effort `low`"

    # a bare child: the session's model and level
    {:ok, child} = Agent.spawn(id, "helper", "help")
    assert_receive {:request, child_body}, 5_000
    assert child_body["model"] == "real-other"
    assert child_body["reasoning"]["effort"] == "low"
    assert Agent.info(child).name == "helper"

    # a role with its own model: the role's, at its own level (the helper's
    # report wakes the parent meanwhile: the picky request is the one with its prompt)
    {:ok, _picky} = Agent.spawn(id, "picky", "be picky", role: "picky")

    picky_body = await_request_matching(~r/be picky/)
    assert picky_body["model"] == "real-model"
    assert picky_body["reasoning"]["effort"] == "high"

    # the children's reports wake (or steer) the parent: wait for the whole team
    # to be quiet before stopping it — a stop mid-stream closes a Bypass handler's
    # socket, and Bypass reports that as the test exiting with shutdown
    await_quiet(id)
    Agent.stop(id)
  end

  # nothing running in the team: the parent idle, every child done
  defp await_quiet(id, tries \\ 40) do
    receive do
      {:thread, _, "turn/completed", _} -> await_quiet(id, tries)
    after
      250 ->
        quiet? =
          Agent.status(id) == :idle and
            Enum.all?(Agent.children(id), &(&1.status != "working"))

        cond do
          quiet? -> :ok
          tries == 0 -> flunk("the team never went quiet")
          true -> await_quiet(id, tries - 1)
        end
    end
  end

  ## more helpers

  # the next request whose instructions match (another agent's may come first)
  defp await_request_matching(regex) do
    receive do
      {:request, %{"instructions" => instructions} = body} when is_binary(instructions) ->
        if Regex.match?(regex, instructions), do: body, else: await_request_matching(regex)
    after
      5_000 -> flunk("no request matching #{inspect(regex)}")
    end
  end

  defp await_item_started(type) do
    receive do
      {:thread, _, "item/started", %{"item" => %{"type" => ^type}} = params} -> params
    after
      5_000 -> flunk("no item/started #{type}")
    end
  end

  # the next completed (or started) dynamicToolCall item of `tool`
  defp await_tool_item(tool, method \\ "item/completed", timeout \\ 5_000) do
    receive do
      {:thread, _, ^method, %{"item" => %{"type" => "dynamicToolCall", "tool" => ^tool} = item}} ->
        item
    after
      timeout -> flunk("no #{method} of #{tool}")
    end
  end

  defp collect_requests(acc) do
    receive do
      {:request, body} -> collect_requests([body | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp await_user_message(text) do
    receive do
      {:thread, _, "item/completed",
       %{"item" => %{"type" => "userMessage", "content" => [%{"text" => ^text}]} = item}} ->
        item
    after
      5_000 ->
        flunk(
          "no user message #{text}; got: #{inspect(mailbox_summary(), pretty: true, limit: 60)}"
        )
    end
  end

  defp await_user_message_matching(regex) do
    receive do
      {:thread, _, "item/completed",
       %{"item" => %{"type" => "userMessage", "content" => [%{"text" => text}]} = item}}
      when is_binary(text) ->
        if Regex.match?(regex, text), do: item, else: await_user_message_matching(regex)
    after
      5_000 -> flunk("no user message matching #{inspect(regex)}")
    end
  end

  # the agent's process leaves (idle_ms) — or has left already
  defp await_gone(thread_id) do
    case Agent.whereis(thread_id) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    end
  end

  # turn ends on the thread until it is idle (a report may start one more turn)
  defp await_idle(thread_id) do
    await_on(thread_id, "turn/completed")
    if Agent.status(thread_id) == :idle, do: :ok, else: await_idle(thread_id)
  end

  defp await_on(thread_id, method) do
    receive do
      {:thread, _seq, ^method, %{"threadId" => ^thread_id} = params} -> params
    after
      5_000 -> flunk("no #{method} on #{thread_id}")
    end
  end

  # a stop that tolerates a process already gone (catch_exit would fail when the stop succeeds)
  defp safe_stop(pid) do
    GenServer.stop(pid, :normal, 5_000)
  catch
    :exit, _ -> :ok
  end

  defp drain_activities do
    receive do
      {:thread, _, _, %{"item" => %{"type" => "subAgentActivity"}}} -> drain_activities()
    after
      0 -> :ok
    end
  end

  defp await_item_completed_of_type(type) do
    receive do
      {:thread, _, "item/completed", %{"item" => %{"type" => ^type}} = params} -> params
    after
      5_000 -> flunk("no item/completed of type #{type}")
    end
  end

  defp await_item_completed(item_id) do
    receive do
      {:thread, _, "item/completed", %{"item" => %{"id" => ^item_id}} = params} -> params
    after
      5_000 -> flunk("no item/completed #{item_id}")
    end
  end

  defp last_agent_text(id) do
    id
    |> ThreadState.snapshot()
    |> Map.fetch!(:items)
    |> Enum.filter(&(&1["type"] == "agentMessage"))
    |> Enum.map(&%{"type" => "text", "text" => &1["text"]})
  end
end
