defmodule Longx.AgentTest do
  use Longx.DataCase, async: false

  alias Longx.Agent
  alias Longx.Agent.Transcript
  alias Longx.AI
  alias Longx.Codex.ThreadState
  alias Longx.Test.ResponsesFixture

  setup do
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
      {:codex, _seq, ^method, params} -> params
    after
      timeout -> flunk("no #{method} event")
    end
  end

  defp await_turn_end(timeout \\ 5_000), do: await("turn/completed", timeout)["turn"]

  defp exec_call(command),
    do: ResponsesFixture.function_call("exec", nil, %{"command" => command})

  ## tests

  test "a question, an answer: events, transcript, request", %{bypass: bypass, thread_id: id} do
    script!(bypass, [ResponsesFixture.assistant_message("hello there")])

    assert {:ok, %{turn_id: turn_id, steered: false}} = Agent.send(id, "hi")

    assert %{"turn" => %{"id" => ^turn_id, "status" => "inProgress"}} = await("turn/started")

    assert %{"item" => %{"type" => "userMessage", "turnId" => ^turn_id} = um} =
             await("item/completed")

    assert [%{"type" => "text", "text" => "hi"}] = um["content"]

    assert %{"item" => %{"type" => "agentMessage", "id" => am}} =
             await_item_started("agentMessage")

    assert %{"itemId" => ^am, "delta" => "hello there"} = await("item/agentMessage/delta")
    assert %{"item" => %{"id" => ^am, "text" => "hello there"}} = await("item/completed")

    assert %{"tokenUsage" => %{"modelContextWindow" => 64_000, "last" => %{"inputTokens" => 12}}} =
             await("thread/tokenUsage/updated")

    assert %{"id" => ^turn_id, "status" => "completed"} = await_turn_end()
    assert Agent.status(id) == :idle

    assert_receive {:request, body}
    assert body["instructions"] =~ "You are"

    assert Enum.map(body["tools"], & &1["name"]) |> Enum.sort() ==
             ~w(edit_file exec read_file write_file)

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
             %{"type" => "function_call", "name" => "exec", "call_id" => call_id},
             %{"type" => "function_call_output", "call_id" => call_id, "output" => output}
           ] = second["input"]

    assert output =~ "hi\n"

    kinds = Transcript.items!(id) |> Enum.map(& &1.kind)
    assert kinds == [:user_message, :function_call, :function_call_output, :agent_message]
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
    assert %{"turnId" => ^turn_id} = await_user_message("also this")

    send(handler, :go)
    assert %{"id" => ^turn_id, "status" => "completed"} = await_turn_end()

    assert_receive {:request, _first}
    assert_receive {:request, second}
    texts = for %{"role" => "user", "content" => [%{"text" => t}]} <- second["input"], do: t
    assert texts == ["first", "also this"]

    assert [%{"type" => "text", "text" => "one"}] = last_agent_text(id) |> Enum.take(1)
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
    refute_receive {:codex, _, "item/agentMessage/delta", _}, 300

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

  ## more helpers

  defp await_item_started(type) do
    receive do
      {:codex, _, "item/started", %{"item" => %{"type" => ^type}} = params} -> params
    after
      5_000 -> flunk("no item/started #{type}")
    end
  end

  defp await_user_message(text) do
    receive do
      {:codex, _, "item/completed",
       %{"item" => %{"type" => "userMessage", "content" => [%{"text" => ^text}]} = item}} ->
        item
    after
      5_000 -> flunk("no user message #{text}")
    end
  end

  defp await_item_completed(item_id) do
    receive do
      {:codex, _, "item/completed", %{"item" => %{"id" => ^item_id}} = params} -> params
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
