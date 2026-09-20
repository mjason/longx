defmodule Longx.Projects.ThreadsTest do
  @moduledoc """
  Threads and turns through `Longx.Projects` on the agent kernel: the rows,
  the git bookmarks, the Tracker completing them, the notify feed, restore.
  Bypass plays the model.
  """
  use Longx.DataCase, async: false

  alias Longx.Agent
  alias Longx.Agent.Transcript
  alias Longx.AI
  alias Longx.Agent.ThreadState
  alias Longx.Git
  alias Longx.Projects
  alias Longx.Projects.{Thread, Turn}
  alias Longx.Test.ResponsesFixture

  setup do
    Ash.bulk_destroy!(Turn, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(Thread, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(Projects.Project, :destroy, %{}, authorize?: false)
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
        reasoning_levels: ["low", "high"],
        reasoning_effort: "low"
      })

    AI.make_default_model!(model)

    dir = Path.join(System.tmp_dir!(), "longx-native-#{n}")
    File.mkdir_p!(dir)
    :ok = Git.init(dir)
    File.write!(Path.join(dir, "a.txt"), "v1\n")
    {:ok, _} = Git.commit_all(dir, "base")

    project =
      Projects.create_project!(%{name: "Threads #{n}", root_path: dir})

    on_exit(fn ->
      Longx.Test.Agents.stop_all!()
      File.rm_rf!(dir)
    end)

    %{bypass: bypass, dir: dir, project: project, model: model}
  end

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

  defp script!(bypass, replies) do
    {:ok, queue} = Elixir.Agent.start_link(fn -> replies end)
    test = self()

    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, Jason.decode!(body)})

      case Elixir.Agent.get_and_update(queue, fn [h | t] -> {h, t} end) do
        reply when is_function(reply, 1) -> reply.(conn)
        reply when is_function(reply, 2) -> reply.(Jason.decode!(body), conn)
        chunks when is_list(chunks) -> sse(conn, chunks)
      end
    end)
  end

  defp held(chunks) do
    test = self()

    fn conn ->
      send(test, {:held, self()})

      receive do
        :go -> sse(conn, chunks)
      end
    end
  end

  defp assert_eventually_ok(fun, tries \\ 50) do
    if fun.() do
      :ok
    else
      if tries == 0, do: flunk("condition never held")
      Process.sleep(50)
      assert_eventually_ok(fun, tries - 1)
    end
  end

  defp turn!(id), do: Ash.get!(Turn, id)
  defp thread!(id), do: Ash.get!(Thread, id)

  test "start_thread/2 starts an agent under a kernel id and records the row", %{
    project: project,
    model: model
  } do
    {:ok, thread} = Projects.start_thread(project, effort: "high")

    assert "native_" <> _ = thread.kernel_thread_id
    assert thread.model_slug == nil
    assert thread.reasoning_effort == "high"
    assert thread.web_search == true
    assert Agent.whereis(thread.kernel_thread_id)

    {:ok, quiet} = Projects.start_thread(project, web_search: false)
    assert quiet.web_search == false

    assert {:error, _} = Projects.start_thread(project, model: "nope")
    assert {:error, _} = Projects.start_thread(project, model: model.slug, effort: "ultra")
  end

  test "a message is a turn the Tracker completes with its git bookmarks", %{
    bypass: bypass,
    project: project,
    dir: dir,
    model: model
  } do
    script!(bypass, [ResponsesFixture.assistant_message("hi back")])
    {:ok, thread} = Projects.start_thread(project)
    File.write!(Path.join(dir, "a.txt"), "v2\n")

    {:ok, turn} = Projects.send_message(thread, "hello")
    assert turn.status == :in_progress
    assert thread!(thread.id).status == :active

    assert_eventually_ok(fn -> turn!(turn.id).status == :completed end)
    turn = turn!(turn.id)
    # the turn's own token usage lands on the row (the badge survives a restart)
    assert %{"inputTokens" => 12, "outputTokens" => _, "totalTokens" => _} = turn.usage
    assert thread!(thread.id).status == :idle
    assert thread!(thread.id).preview == "hello"

    assert_receive {:request, body}
    assert body["reasoning"]["effort"] == "low"
    # the agent knows the models it may name in its description
    assert body["instructions"] =~ "`#{model.slug}`"
    assert [_, %{kind: :agent_message}] = Transcript.items!(thread.kernel_thread_id)

    assert {:error, :not_running} = Projects.steer_message(thread, "late")
  end

  test "steer, interrupt and retract go to the kernel", %{bypass: bypass, project: project} do
    script!(bypass, [
      held(ResponsesFixture.assistant_message("one")),
      ResponsesFixture.assistant_message("two"),
      held(ResponsesFixture.assistant_message("three")),
      held(ResponsesFixture.assistant_message("four"))
    ])

    {:ok, thread} = Projects.start_thread(project)

    {:ok, turn} = Projects.send_message(thread, "first")
    assert_receive {:held, h1}, 5_000
    assert {:ok, %{kernel_turn_id: id}} = Projects.steer_message(thread, "and this")
    assert id == turn.kernel_turn_id
    assert {:error, :turn_in_progress} = Projects.send_message(thread, "no")
    send(h1, :go)
    assert_eventually_ok(fn -> turn!(turn.id).status == :completed end)

    {:ok, turn2} = Projects.send_message(thread, "second")
    assert_receive {:held, _h2}, 5_000
    Bypass.pass(bypass)
    assert :ok = Projects.interrupt_turn(thread, turn2.kernel_turn_id)
    assert_eventually_ok(fn -> turn!(turn2.id).status == :interrupted end)

    {:ok, turn3} = Projects.send_message(thread, "third")
    assert_receive {:held, _h3}, 5_000
    assert {:ok, %{text: "third"}} = Projects.retract_turn(thread, turn3)
    assert turn!(turn3.id).status == :reverted
    assert thread!(thread.id).status == :idle

    refute Enum.any?(
             Transcript.items!(thread.kernel_thread_id),
             &(&1.turn_id == turn3.kernel_turn_id)
           )
  end

  test "an agent that dies mid-turn: the turn fails at once with the reason, the thread is idle again and takes the next message",
       %{bypass: bypass, project: project} do
    script!(bypass, [
      held(ResponsesFixture.assistant_message("never")),
      ResponsesFixture.assistant_message("back")
    ])

    {:ok, thread} = Projects.start_thread(project)
    {:ok, turn} = Projects.send_message(thread, "first")
    assert_receive {:held, held}, 5_000
    Bypass.pass(bypass)

    # the kernel process is killed (a bug, an OOM, a hot reload in dev): no
    # turn/completed will ever come
    pid = Agent.whereis(thread.kernel_thread_id)
    assert is_pid(pid)
    Process.exit(pid, :kill)
    send(held, :go)

    assert_eventually_ok(fn -> turn!(turn.id).status == :failed end)
    assert turn!(turn.id).error =~ "killed"
    assert thread!(thread.id).status == :idle

    {:ok, turn2} = Projects.send_message(thread, "again")
    assert_eventually_ok(fn -> turn!(turn2.id).status == :completed end)
  end

  test "opening a thread after a restart starts its agent again; deleting it drops the log", %{
    bypass: bypass,
    project: project
  } do
    script!(bypass, [ResponsesFixture.assistant_message("kept")])
    {:ok, thread} = Projects.start_thread(project)
    {:ok, turn} = Projects.send_message(thread, "remember")
    assert_eventually_ok(fn -> turn!(turn.id).status == :completed end)

    :ok = Agent.stop(thread.kernel_thread_id)
    :ok = ThreadState.stop(thread.kernel_thread_id)
    :ok = ThreadState.Store.delete(thread.kernel_thread_id)

    assert {:ok, id} = Projects.host_thread(thread.kernel_thread_id)
    assert id == thread.kernel_thread_id
    assert Agent.whereis(id)
    snapshot = ThreadState.snapshot(id)
    assert length(snapshot.items) == 2
    # the turns come back from the rows: stamps and usage for every past turn's badge
    kernel_turn = turn.kernel_turn_id

    assert %{
             ^kernel_turn => %{
               "status" => "completed",
               "startedAt" => started,
               "completedAt" => completed,
               "usage" => %{"inputTokens" => 12}
             }
           } =
             snapshot.turns

    assert is_number(started) and is_number(completed) and completed >= started

    assert :ok = Projects.delete_thread(thread)
    assert Transcript.items!(id) == []
    refute Agent.whereis(id)
  end

  test "search_files/2 walks the tree: the query as a subsequence, shortest paths first", %{
    project: project,
    dir: dir
  } do
    File.mkdir_p!(Path.join(dir, "lib/deep"))
    File.write!(Path.join(dir, "lib/deep/math_helper.ex"), "")
    File.write!(Path.join(dir, "notes.md"), "")

    assert {:ok, [%{path: "lib/deep/math_helper.ex", file_name: "math_helper.ex"}]} =
             Projects.search_files(project, "mhelp")

    assert {:ok, [%{path: "a.txt"} | _]} = Projects.search_files(project, "a")
    assert {:ok, []} = Projects.search_files(project, "zzz")
    assert {:ok, []} = Projects.search_files(project, "")
  end

  test "the project's own agent definition is loaded only once trusted; the settings page sees it",
       %{bypass: bypass, project: project, dir: dir} do
    File.mkdir_p!(Path.join(dir, ".longx/plugs"))

    File.write!(Path.join(dir, ".longx/plugs/deploy.exs"), """
    defmodule Deploy do
      use Longx.Agent.Plug
      tool :deploy, "ships it" do
        param :env, :string, "target", required: true
      end
      def deploy(_args, _ctx), do: {:ok, "ok"}
    end
    """)

    File.write!(
      Path.join(dir, ".longx/agent.exs"),
      "import Longx.Agent.Config\nagent do\n  plug Deploy\nend\n"
    )

    definition = Projects.agent_definition(project)

    assert %{
             present: true,
             trusted: false,
             files: [".longx/agent.exs", ".longx/plugs/deploy.exs"]
           } = definition

    refute Enum.any?(definition.plugs, &(&1 =~ "Deploy"))

    script!(bypass, [
      ResponsesFixture.assistant_message("a"),
      ResponsesFixture.assistant_message("b")
    ])

    {:ok, thread} = Projects.start_thread(project)
    {:ok, turn} = Projects.send_message(thread, "hi")
    assert_eventually_ok(fn -> turn!(turn.id).status == :completed end)
    assert_receive {:request, body}
    refute "deploy" in Enum.map(body["tools"], & &1["name"])

    project = Projects.update_project!(project, %{trust_local_agent: true})
    assert %{trusted: true} = definition = Projects.agent_definition(project)
    assert "Deploy (.longx)" in definition.plugs

    {:ok, turn} = Projects.send_message(thread, "again")
    assert_eventually_ok(fn -> turn!(turn.id).status == :completed end)
    assert_receive {:request, body}
    assert "deploy" in Enum.map(body["tools"], & &1["name"])
  end

  test "the directory: handles name sessions, addresses resolve, a message goes to a session by address and its answer comes back",
       %{bypass: bypass, project: project} do
    {:ok, main} = Projects.start_thread(project)
    {:ok, other} = Projects.start_thread(project)

    # a handle: a slug, unique in the project; ~<id suffix> stands in without one
    assert {:ok, %Thread{handle: "main"}} = Projects.set_handle(main, "main")
    assert {:error, _} = Projects.set_handle(other, "main")
    assert {:error, _} = Projects.set_handle(other, "Not A Slug")
    assert Projects.agent_name(thread!(main.id)) == "main"
    assert "~" <> suffix = Projects.agent_name(other)
    assert String.ends_with?(other.id, suffix) and String.length(suffix) == 6

    # the directory: every root session of the project with its state
    assert [%{handle: "main", state: :idle} = row, %{handle: nil, state: :idle}] =
             Projects.directory(project.id) |> Enum.sort_by(&(&1.handle || "zz"))

    assert row.address == "main"
    assert row.thread_id == main.id
    assert row.kernel_thread_id == main.kernel_thread_id
    assert row.team == []

    # addresses: a handle, ~suffix, project:handle; unknown is not found
    assert {:ok, %Thread{id: id}} = Projects.resolve_address(project.id, "main")
    assert id == main.id
    assert {:ok, %Thread{id: id}} = Projects.resolve_address(project.id, "~" <> suffix)
    assert id == other.id
    assert {:ok, %Thread{id: id}} = Projects.resolve_address(project.id, "#{project.slug}:main")
    assert id == main.id
    assert {:error, :not_found} = Projects.resolve_address(project.id, "nobody")

    # a message by address: a turn on the target, with a row, from the sender's name;
    # the target's answer comes back into the sender's mailbox as a turn of its own
    script!(bypass, [
      ResponsesFixture.assistant_message("main here: 42"),
      ResponsesFixture.assistant_message("noted")
    ])

    assert {:ok, %Thread{id: id}} =
             Projects.deliver(project.id, "main", "what is the answer?",
               from_thread: other.kernel_thread_id
             )

    assert id == main.id

    assert_eventually_ok(fn ->
      match?([%Turn{status: :completed, user_text: "（agent 消息）"}], Projects.list_turns!(main))
    end)

    # the list shows the words, not the prefix the model reads
    assert_eventually_ok(fn -> thread!(main.id).preview == "what is the answer?" end)

    assert %{items: items} = ThreadState.snapshot(main.kernel_thread_id)

    assert Enum.any?(items, fn item ->
             item["type"] == "userMessage" and item["from"] == "~" <> suffix and
               hd(item["content"])["text"] == "[agent ~#{suffix}] what is the answer?"
           end)

    assert_eventually_ok(fn ->
      match?([%Turn{status: :completed}], Projects.list_turns!(other))
    end)

    assert %{items: items} = ThreadState.snapshot(other.kernel_thread_id)

    assert Enum.any?(items, fn item ->
             item["type"] == "userMessage" and item["from"] == "main" and
               hd(item["content"])["text"] == "[agent main] main here: 42"
           end)

    # to oneself, to nobody, to an archived session: refused
    assert {:error, :self} =
             Projects.deliver(project.id, "main", "hi", from_thread: main.kernel_thread_id)

    assert {:error, :not_found} = Projects.deliver(project.id, "ghost", "hi", [])
    {:ok, _} = Projects.archive_thread(other)
    assert {:error, :not_found} = Projects.resolve_address(project.id, "~" <> suffix)

    # the directory state follows the process: gone = asleep
    Agent.stop(main.kernel_thread_id)
    assert [%{handle: "main", state: :asleep}] = Projects.directory(project.id)
  end

  test "on duty: a plain conversation of the person's cannot be woken by another agent; the switch, a handle or an active goal put a session on duty",
       %{bypass: bypass, project: project} do
    {:ok, asker} = Projects.start_thread(project)
    {:ok, plain} = Projects.start_thread(project)
    {:ok, named} = Projects.start_thread(project, handle: "ops")
    {:ok, driven} = Projects.start_thread(project)
    address = Projects.agent_name(plain)

    # the directory says who is on duty
    rows = Projects.directory(project.id)
    assert %{on_duty: false} = Enum.find(rows, &(&1.thread_id == plain.id))
    assert %{on_duty: true} = Enum.find(rows, &(&1.thread_id == named.id))

    # a message to a conversation is refused — nothing starts there
    assert {:error, :off_duty} =
             Projects.deliver(project.id, address, "did you write this?",
               from_thread: asker.kernel_thread_id
             )

    assert Projects.list_turns!(plain) == []

    # the switch
    assert {:ok, %Thread{on_duty: true}} = Projects.set_on_duty(plain, true)

    assert %{on_duty: true} =
             Enum.find(Projects.directory(project.id), &(&1.thread_id == plain.id))

    # its answer wakes the asker — a conversation itself, off duty: a reply is not a call
    script!(bypass, [
      ResponsesFixture.assistant_message("yes, mine"),
      ResponsesFixture.assistant_message("noted")
    ])

    assert {:ok, %Thread{id: id}} =
             Projects.deliver(project.id, address, "did you write this?",
               from_thread: asker.kernel_thread_id
             )

    assert id == plain.id

    assert_eventually_ok(fn ->
      match?([%Turn{status: :completed}], Projects.list_turns!(plain))
    end)

    assert_eventually_ok(fn ->
      match?([%Turn{status: :completed}], Projects.list_turns!(asker))
    end)

    assert {:ok, %Thread{on_duty: false}} = Projects.set_on_duty(plain, false)

    # an active goal is a duty as well
    {:ok, _} = Agent.set_goal(driven.kernel_thread_id, %{"objective" => "keep the build green"})

    assert %{on_duty: true} =
             Enum.find(Projects.directory(project.id), &(&1.thread_id == driven.id))
  end

  test "the Agents plug: the prompt names this session and the others; agents_directory, claim_handle and send_message by address",
       %{bypass: bypass, project: project} do
    {:ok, ops} = Projects.start_thread(project, handle: "ops", title: "值班")
    {:ok, thread} = Projects.start_thread(project)
    # a conversation the person had: not a colleague
    {:ok, chat} = Projects.start_thread(project, title: "聊聊架构")

    by_content = fn body, conn ->
      texts = for %{"role" => "user", "content" => [%{"text" => t}]} <- body["input"], do: t

      cond do
        Enum.any?(texts, &(&1 =~ "[agent main] 服务还好吗")) ->
          sse(conn, ResponsesFixture.assistant_message("all good"))

        Enum.any?(texts, &(&1 =~ "[agent ops] all good")) ->
          sse(conn, ResponsesFixture.assistant_message("thanks"))

        true ->
          sse(conn, ResponsesFixture.assistant_message("asked ops"))
      end
    end

    script!(bypass, [
      ResponsesFixture.function_call("agents_directory", nil, %{}),
      ResponsesFixture.function_call("claim_handle", nil, %{"handle" => "main"}),
      ResponsesFixture.function_call("send_message", nil, %{
        "to" => "ops",
        "message" => "服务还好吗？",
        "deliver" => "idle"
      }),
      # the two sessions' requests race for the queue: the reply reads the request
      by_content,
      by_content,
      by_content
    ])

    :ok = ThreadState.subscribe(thread.kernel_thread_id)
    {:ok, turn} = Projects.send_message(thread, "check on ops")

    assert_eventually_ok(fn -> turn!(turn.id).status == :completed end)

    assert_receive {:request, first}
    prompt = first["instructions"]
    assert prompt =~ "# Sessions in this project"
    assert prompt =~ "- ops — 值班"
    assert prompt =~ "Others reach you as `~" <> String.slice(thread.id, -6, 6)
    # the person's conversation is not offered as a colleague
    refute prompt =~ "聊聊架构"
    assert prompt =~ "not on duty"

    # the directory tool: every session, states, addresses, who is on duty
    assert_receive {:request, second}

    [%{"output" => directory}] =
      for %{"type" => "function_call_output"} = o <- second["input"], do: o

    assert directory =~ "ops"
    assert directory =~ "idle"
    assert directory =~ "running"
    assert directory =~ "on duty"
    assert directory =~ "#{Projects.agent_name(chat)} [idle · conversation] — 聊聊架构"

    # claim_handle names this session; the later prompt says so
    assert_receive {:request, third}
    assert thread!(thread.id).handle == "main"
    assert third["instructions"] =~ "You are `main`"

    # send_message by address, delivered when idle: a turn on ops from main, its answer back to main
    # (the two sessions' requests race: pick main's by its content)
    assert_receive {:request, %{"input" => input}}
                   when is_list(input) and length(input) > 5,
                   5_000

    assert Enum.any?(input, fn
             %{"type" => "function_call_output", "output" => out} -> out =~ "delivered to ops"
             _ -> false
           end)

    assert_eventually_ok(fn ->
      match?([%Turn{status: :completed, user_text: "（agent 消息）"}], Projects.list_turns!(ops))
    end)

    assert_eventually_ok(fn ->
      match?(
        [_, %Turn{status: :completed, user_text: "（agent 消息）"}],
        Projects.list_turns!(thread)
      )
    end)

    assert %{items: items} = ThreadState.snapshot(thread.kernel_thread_id)

    assert Enum.any?(items, fn item ->
             item["type"] == "userMessage" and item["from"] == "ops" and
               hd(item["content"])["text"] == "[agent ops] all good"
           end)
  end

  test "deleting a thread takes its sub-agents' rows, turns and transcripts with it", %{
    bypass: bypass,
    project: project
  } do
    script!(bypass, [
      ResponsesFixture.assistant_message("REPORT: done"),
      ResponsesFixture.assistant_message("thanks")
    ])

    {:ok, thread} = Projects.start_thread(project)
    assert {:ok, child_id} = Agent.spawn(thread.kernel_thread_id, "researcher", "look it up")
    assert [%Thread{kernel_thread_id: ^child_id} = child] = Projects.list_subagents!(thread.id)

    # the child's report wakes the parent: that turn too must be over before the
    # delete (a delete mid-stream closes a Bypass handler's socket, which Bypass
    # reports as the test exiting with shutdown)
    assert_eventually_ok(fn ->
      match?([%Turn{status: :completed}], Projects.list_turns!(thread)) and
        thread!(child.id).status == :idle and thread!(thread.id).status == :idle
    end)

    assert :ok = Projects.delete_thread(thread!(thread.id))
    assert {:error, _} = Ash.get(Thread, thread.id)
    assert {:error, _} = Ash.get(Thread, child.id)
    assert [] = Projects.list_turns!(child)
    assert [] = Transcript.items!(child_id)
    assert Agent.whereis(child_id) == nil
  end

  test "a closed child is archived: a restart's team rebuild leaves it out, and a new child may take its name",
       %{bypass: bypass, project: project} do
    script!(bypass, [
      ResponsesFixture.assistant_message("REPORT: done"),
      ResponsesFixture.assistant_message("thanks"),
      ResponsesFixture.assistant_message("REPORT: done again"),
      ResponsesFixture.assistant_message("thanks again")
    ])

    {:ok, thread} = Projects.start_thread(project)
    assert {:ok, child_id} = Agent.spawn(thread.kernel_thread_id, "researcher", "look it up")
    assert [%Thread{kernel_thread_id: ^child_id} = child] = Projects.list_subagents!(thread.id)

    assert_eventually_ok(fn ->
      match?([%Turn{status: :completed}], Projects.list_turns!(thread)) and
        thread!(child.id).status == :idle and thread!(thread.id).status == :idle
    end)

    # closed through the tool's path: forgotten, stopped, spec gone — and the row archived
    ctx = %Longx.Agent.Context{thread_id: thread.kernel_thread_id, project_id: project.id}

    assert {:ok, "agent researcher closed; its status was " <> _} =
             Longx.Agent.Plugs.Agents.close_agent(%{"agent" => "researcher"}, ctx)

    assert thread!(child.id).status == :archived
    assert Projects.list_subagents!(thread.id) == []
    assert Agent.children(thread.kernel_thread_id) == []

    # a second researcher takes the plain name; after the parent is gone and hosted again
    # (a restart rebuilds the team from the rows) the team has one researcher, not two
    assert {:ok, child2} = Agent.spawn(thread.kernel_thread_id, "researcher", "look again")
    assert [%Thread{kernel_thread_id: ^child2}] = Projects.list_subagents!(thread.id)

    assert_eventually_ok(fn ->
      match?([_, %Turn{status: :completed}], Projects.list_turns!(thread)) and
        thread!(thread.id).status == :idle
    end)

    Longx.Test.Agents.stop_all!()
    Longx.Agent.Kernel.Specs.delete(thread.kernel_thread_id)
    Longx.Agent.Kernel.Specs.delete(child_id)
    Longx.Agent.Kernel.Specs.delete(child2)
    assert {:ok, _} = Projects.host_thread(thread.kernel_thread_id)
    assert [%{name: "researcher", id: ^child2}] = Agent.children(thread.kernel_thread_id)

    # deleting the parent takes the archived child's row too (a leftover row would break the delete)
    Longx.Test.Agents.stop_all!()
    assert :ok = Projects.delete_thread(thread!(thread.id))
    assert {:error, _} = Ash.get(Thread, child.id)
    assert [] = Transcript.items!(child_id)
  end

  test "the stall watchdog interrupts a turn with no progress even while pages keep joining the thread",
       %{bypass: bypass, project: project} do
    previous = Application.get_env(:longx, Projects.Tracker, [])
    Application.put_env(:longx, Projects.Tracker, stall_after: 400, tick: 100)
    on_exit(fn -> Application.put_env(:longx, Projects.Tracker, previous) end)

    script!(bypass, [held(ResponsesFixture.assistant_message("never"))])
    {:ok, thread} = Projects.start_thread(project)
    {:ok, turn} = Projects.send_message(thread, "hang")
    assert_receive {:held, _handler}, 5_000

    # pages keep opening the thread (a join → host_thread → track): not progress
    joiner =
      Task.async(fn ->
        for _ <- 1..30 do
          Process.sleep(100)
          {:ok, _} = Projects.host_thread(thread.kernel_thread_id)
        end
      end)

    # well within the joiner's three seconds
    assert_eventually_ok(
      fn -> match?(%Turn{status: :interrupted, error: "no progress" <> _}, turn!(turn.id)) end,
      30
    )

    Task.await(joiner, 5_000)
    Bypass.pass(bypass)
  end

  test "the Tracker knows which threads have a turn in flight (the monitor on the agent is the truth); the watchdog looks only at those",
       %{bypass: bypass, project: project} do
    script!(bypass, [held(ResponsesFixture.assistant_message("one"))])
    {:ok, thread} = Projects.start_thread(project)
    refute thread.kernel_thread_id in Projects.Tracker.in_flight()

    {:ok, turn} = Projects.send_message(thread, "go")
    assert_receive {:held, h}, 5_000
    assert_eventually_ok(fn -> thread.kernel_thread_id in Projects.Tracker.in_flight() end)

    send(h, :go)
    assert_eventually_ok(fn -> turn!(turn.id).status == :completed end)
    assert_eventually_ok(fn -> thread.kernel_thread_id not in Projects.Tracker.in_flight() end)
  end

  test "a Tracker that restarts mid-turn recovers what is in flight from the rows: the running turn still completes, an orphaned row is settled",
       %{bypass: bypass, project: project} do
    script!(bypass, [held(ResponsesFixture.assistant_message("one"))])
    {:ok, thread} = Projects.start_thread(project)
    {:ok, turn} = Projects.send_message(thread, "go")
    assert_receive {:held, h}, 5_000

    # a row whose agent will never speak (a thread nobody hosts)
    {:ok, ghost} = Projects.start_thread(project)
    Agent.stop(ghost.kernel_thread_id)

    {:ok, orphan} =
      Projects.create_turn(%{
        kernel_turn_id: "turn_" <> Ash.UUID.generate(),
        thread_id: ghost.id,
        user_text: "lost",
        started_at: DateTime.utc_now()
      })

    Projects.touch_thread!(thread!(ghost.id), %{status: :active})

    tracker = Process.whereis(Projects.Tracker)
    ref = Process.monitor(tracker)
    Process.exit(tracker, :kill)
    assert_receive {:DOWN, ^ref, :process, ^tracker, :killed}
    assert_eventually_ok(fn -> Process.whereis(Projects.Tracker) not in [nil, tracker] end)

    # the new Tracker found the running turn in the rows and follows it again
    assert_eventually_ok(fn -> thread.kernel_thread_id in Projects.Tracker.in_flight() end)
    send(h, :go)
    assert_eventually_ok(fn -> turn!(turn.id).status == :completed end)
    assert thread!(thread.id).status == :idle

    # and settled the row with no agent behind it
    assert_eventually_ok(fn -> turn!(orphan.id).status == :failed end)
    assert thread!(ghost.id).status == :idle
  end

  test "the stall watchdog settles a turn whose agent is no longer running instead of leaving the thread active for ever",
       %{bypass: bypass, project: project} do
    previous = Application.get_env(:longx, Projects.Tracker, [])
    Application.put_env(:longx, Projects.Tracker, stall_after: 400, tick: 100)
    on_exit(fn -> Application.put_env(:longx, Projects.Tracker, previous) end)

    script!(bypass, [
      ResponsesFixture.assistant_message("done"),
      ResponsesFixture.assistant_message("again")
    ])

    {:ok, thread} = Projects.start_thread(project)
    {:ok, first} = Projects.send_message(thread, "hi")
    assert_eventually_ok(fn -> turn!(first.id).status == :completed end)

    # a row left open with the thread active while the agent sits idle
    # (a crash the monitor missed — a restart of the Tracker itself, say)
    {:ok, stale} =
      Projects.create_turn(%{
        kernel_turn_id: "turn_" <> Ash.UUID.generate(),
        thread_id: thread.id,
        user_text: "lost",
        started_at: DateTime.utc_now()
      })

    Projects.touch_thread!(thread!(thread.id), %{status: :active})
    assert {:error, :turn_in_progress} = Projects.send_message(thread, "blocked")

    assert_eventually_ok(fn -> turn!(stale.id).status == :failed end, 30)
    assert turn!(stale.id).error =~ "no longer running"
    assert thread!(thread.id).status == :idle
    {:ok, next} = Projects.send_message(thread, "again")
    assert_eventually_ok(fn -> turn!(next.id).status == :completed end)
  end

  test "a thread whose sub-agent is still working counts as running on the welcome page, naming the agent",
       %{bypass: bypass, project: project} do
    script!(bypass, [
      ResponsesFixture.assistant_message("delegated"),
      held(ResponsesFixture.assistant_message("REPORT: done")),
      ResponsesFixture.assistant_message("thanks")
    ])

    {:ok, thread} = Projects.start_thread(project)
    {:ok, first} = Projects.send_message(thread, "hi")
    assert_eventually_ok(fn -> turn!(first.id).status == :completed end)
    assert Projects.running_threads() == []

    # the parent is idle, the child at work: the session is busy
    assert {:ok, _child_id} = Agent.spawn(thread.kernel_thread_id, "researcher", "look it up")
    assert_receive {:held, handler}, 5_000
    assert_eventually_ok(fn -> thread!(thread.id).status == :idle end)

    assert [%{id: id, waiting: false, working: ["researcher"]}] = Projects.running_threads()
    assert id == thread.id
    # the directory says so too
    assert [%{state: :running, team: ["researcher"]}] = Projects.directory(project.id)

    send(handler, :go)

    assert_eventually_ok(fn ->
      match?([_, %Turn{status: :completed}], Projects.list_turns!(thread)) and
        thread!(thread.id).status == :idle
    end)

    assert Projects.running_threads() == []
  end

  test "session_named/3 finds the session with that handle or starts one", %{project: project} do
    assert {:ok, %Thread{handle: "watch-deploy", title: "⏰ deploy"} = thread} =
             Projects.session_named(project, "watch-deploy", title: "⏰ deploy")

    assert {:ok, %Thread{id: id}} = Projects.session_named(project, "watch-deploy", title: "x")
    assert id == thread.id
    assert [_] = Projects.list_threads!(project)
  end

  test "a child agent is a thread row under its parent; its report is a turn of the parent", %{
    bypass: bypass,
    project: project
  } do
    script!(bypass, [
      ResponsesFixture.assistant_message("delegating"),
      ResponsesFixture.assistant_message("REPORT: done"),
      ResponsesFixture.assistant_message("thanks")
    ])

    {:ok, thread} = Projects.start_thread(project)
    {:ok, first} = Projects.send_message(thread, "hi")
    assert_eventually_ok(fn -> turn!(first.id).status == :completed end)
    # a goal on the parent does not make a child's report a "goal continuation" row
    {:ok, _} =
      Agent.set_goal(thread.kernel_thread_id, %{"objective" => "find it", "status" => "paused"})

    assert {:ok, child_id} = Agent.spawn(thread.kernel_thread_id, "researcher", "look it up")
    assert [%Thread{kernel_thread_id: ^child_id} = child] = Projects.list_subagents!(thread.id)
    assert child.title == "researcher"
    assert child.agent_path == "/root/researcher"
    assert child.parent_thread_id == thread.id
    assert child.cwd == thread.cwd
    assert %{parent: parent_id, name: "researcher"} = Agent.info(child_id)
    assert parent_id == thread.kernel_thread_id

    # the child's task is a turn of its own; the report wakes the parent into a turn with a row
    assert_eventually_ok(fn ->
      match?([%Turn{status: :completed, user_text: "look it up"}], Projects.list_turns!(child))
    end)

    assert_eventually_ok(fn ->
      match?(
        [%Turn{status: :completed}, %Turn{status: :completed, user_text: "（agent 消息）"}],
        Projects.list_turns!(thread)
      )
    end)

    # the Tracker idles the thread in a write after the turn row's
    assert_eventually_ok(fn ->
      thread!(child.id).status == :idle and thread!(thread.id).status == :idle
    end)

    assert %{items: items} = ThreadState.snapshot(thread.kernel_thread_id)

    assert Enum.any?(items, fn item ->
             item["type"] == "userMessage" and item["from"] == "researcher" and
               hd(item["content"])["text"] == "[agent researcher] REPORT: done"
           end)

    # a restart forgets nothing: the child comes back knowing its parent
    Agent.stop(child_id)
    assert {:ok, ^child_id} = Projects.host_thread(child_id)
    assert %{parent: ^parent_id, name: "researcher"} = Agent.info(child_id)
  end

  test "after a restart the team is rebuilt from the rows: the parent still lists its child and a follow-up reaches it",
       %{bypass: bypass, project: project} do
    script!(bypass, [
      ResponsesFixture.assistant_message("delegating"),
      ResponsesFixture.assistant_message("REPORT: done"),
      ResponsesFixture.assistant_message("thanks"),
      ResponsesFixture.assistant_message("MORE: 42"),
      ResponsesFixture.assistant_message("noted")
    ])

    {:ok, thread} = Projects.start_thread(project)
    {:ok, first} = Projects.send_message(thread, "hi")
    assert_eventually_ok(fn -> turn!(first.id).status == :completed end)
    parent_id = thread.kernel_thread_id
    assert {:ok, child_id} = Agent.spawn(parent_id, "researcher", "look it up")

    assert_eventually_ok(fn ->
      match?([%Turn{status: :completed}, %Turn{status: :completed}], Projects.list_turns!(thread))
    end)

    # a BEAM restart: the processes and the specs are gone, the rows remain
    Agent.stop(parent_id)
    Longx.Agent.Kernel.Specs.delete(child_id)
    Longx.Agent.Kernel.Specs.delete(parent_id)

    assert {:ok, ^parent_id} = Projects.host_thread(parent_id)

    assert [%{id: ^child_id, name: "researcher", status: "done", task: "look it up"}] =
             Agent.children(parent_id)

    # the follow-up revives the child from its row; its answer is a turn of the parent again
    assert {:ok, %{steered: false}} =
             Agent.send(child_id, "and more?", from: "main", reply_to: parent_id)

    assert_eventually_ok(fn ->
      match?(
        [_, _, %Turn{status: :completed, user_text: "（agent 消息）"}],
        Projects.list_turns!(thread)
      )
    end)

    [child] = Projects.list_subagents!(thread.id)

    assert [%Turn{user_text: "look it up"}, %Turn{status: :completed}] =
             Projects.list_turns!(child)
  end

  test "a plug of the project asks the person; the answer goes through Projects, the feed hears of it",
       %{
         bypass: bypass,
         project: project,
         dir: dir
       } do
    File.mkdir_p!(Path.join(dir, ".longx/local/plugs"))

    File.write!(Path.join(dir, ".longx/local/plugs/login.exs"), """
    defmodule Login do
      use Longx.Agent.Plug

      tool :login, "signs the person in" do
      end

      def login(_args, ctx) do
        case Context.ask(ctx, title: "登录", text: "去登录") do
          {:ok, answer} -> {:ok, "answered " <> Jason.encode!(answer)}
          {:error, why} -> {:error, "no: \#{why}"}
        end
      end
    end
    """)

    File.write!(
      Path.join(dir, ".longx/local/agent.exs"),
      "import Longx.Agent.Config\nagent do\n  plug Login\nend\n"
    )

    script!(bypass, [
      ResponsesFixture.function_call("login", nil, %{}),
      ResponsesFixture.assistant_message("done")
    ])

    :ok = Phoenix.PubSub.subscribe(Longx.PubSub, Longx.Notify.topic())
    {:ok, thread} = Projects.start_thread(project)
    :ok = ThreadState.subscribe(thread.kernel_thread_id)
    url = "/p/#{project.slug}/t/#{thread.id}"
    {:ok, turn} = Projects.send_message(thread, "log in")

    assert_receive {:thread, _, "longx/action/request", %{"requestId" => rid}}, 5_000
    # the request = the turn waits on the person; the welcome page says so
    assert_receive {:notify, %{kind: "approval", title: "等待你操作", body: "登录", url: ^url}}, 5_000
    assert [%{id: id, waiting: true}] = Projects.running_threads()
    assert id == thread.id

    assert :ok = Projects.answer_request(thread, rid, %{"done" => true})
    assert_eventually_ok(fn -> turn!(turn.id).status == :completed end)
    assert_receive {:notify, %{kind: "turn_completed", url: ^url}}, 5_000
    assert_receive {:request, _}
    assert_receive {:request, body}
    assert Enum.any?(body["input"], &(&1["output"] == ~s(answered {"done":true})))
    assert Projects.running_threads() == []
  end

  test "a model failure ends the turn failed and the feed says so", %{
    bypass: bypass,
    project: project
  } do
    :ok = Phoenix.PubSub.subscribe(Longx.PubSub, Longx.Notify.topic())

    Bypass.expect_once(bypass, "POST", "/v1/responses", fn conn ->
      Plug.Conn.send_resp(conn, 400, ~s({"error":{"message":"bad request"}}))
    end)

    {:ok, thread} = Projects.start_thread(project)
    {:ok, turn} = Projects.send_message(thread, "break")
    assert_eventually_ok(fn -> turn!(turn.id).status == :failed end)
    assert turn!(turn.id).error =~ "bad request"
    assert_receive {:notify, %{kind: "turn_failed", body: body}}, 5_000
    assert body =~ "bad request"
    assert thread!(thread.id).status == :idle
  end

  test "/compact on an idle thread is the kernel's own; an archived thread takes nothing", %{
    project: project
  } do
    {:ok, thread} = Projects.start_thread(project)
    assert :ok = Projects.compact_thread(thread)

    Projects.archive_thread!(thread)
    assert {:error, :thread_archived} = Projects.send_message(thread, "hi")
    assert {:error, :thread_archived} = Projects.compact_thread(thread)
  end

  test "a goal is set, changed and cleared through the thread; the view carries it", %{
    project: project
  } do
    {:ok, thread} = Projects.start_thread(project)
    :ok = ThreadState.subscribe(thread.kernel_thread_id)

    assert {:ok, %{"objective" => "keep going", "status" => "active", "tokenBudget" => 5000}} =
             Projects.set_goal(thread, %{objective: "keep going", token_budget: 5000})

    assert_receive {:thread, _, "thread/goal/updated",
                    %{"goal" => %{"objective" => "keep going"}}},
                   5_000

    assert %{"objective" => "keep going"} = ThreadState.snapshot(thread.kernel_thread_id).goal

    assert {:ok, %{"status" => "paused", "objective" => "keep going"}} =
             Projects.set_goal(thread, %{status: :paused})

    assert {:ok, true} = Projects.clear_goal(thread)
    assert_receive {:thread, _, "thread/goal/cleared", _}, 5_000
    assert ThreadState.snapshot(thread.kernel_thread_id).goal == nil
    assert {:ok, false} = Projects.clear_goal(thread)

    Projects.archive_thread!(thread)
    assert {:error, :thread_archived} = Projects.set_goal(thread, %{objective: "x"})
  end

  describe "the working tree is the person's" do
    test "a dirty tree is left exactly as it is: Longx never commits, the turn carries no git bookmark",
         %{
           bypass: bypass,
           project: project,
           dir: dir
         } do
      script!(bypass, [ResponsesFixture.assistant_message("ok")])
      {:ok, before} = Git.head(dir)
      File.write!(Path.join(dir, "a.txt"), "edited by hand\n")
      {:ok, thread} = Projects.start_thread(project)

      {:ok, turn} = Projects.send_message(thread, "say ok")
      refute Map.has_key?(turn, :commit_before)
      refute Map.has_key?(turn, :dirty_start)
      assert %{clean?: false} = Git.status(dir)
      assert {:ok, ^before} = Git.head(dir)
      assert_eventually_ok(fn -> turn!(turn.id).status == :completed end)
      # still nothing of ours on the branch
      assert {:ok, ^before} = Git.head(dir)
      assert File.read!(Path.join(dir, "a.txt")) == "edited by hand\n"
    end

    test "a project without git works the same", %{bypass: bypass} do
      script!(bypass, [ResponsesFixture.assistant_message("fine")])
      plain = Path.join(System.tmp_dir!(), "longx-plain-#{System.unique_integer([:positive])}")
      File.mkdir_p!(plain)
      on_exit(fn -> File.rm_rf!(plain) end)
      project = Projects.create_project!(%{name: "Plain", root_path: plain})

      {:ok, thread} = Projects.start_thread(project)
      {:ok, turn} = Projects.send_message(thread, "say fine")
      assert_eventually_ok(fn -> turn!(turn.id).status == :completed end)
    end

    test "model: and effort: switch for this and later turns, recorded on the thread and the turn",
         %{bypass: bypass, project: project, model: model} do
      script!(bypass, [
        ResponsesFixture.assistant_message("a"),
        ResponsesFixture.assistant_message("b"),
        ResponsesFixture.assistant_message("c")
      ])

      {:ok, thread} = Projects.start_thread(project)
      assert thread.reasoning_effort == "low"

      {:ok, turn} = Projects.send_message(thread, "say a", effort: "high")
      assert turn.reasoning_effort == "high"
      assert thread!(thread.id).reasoning_effort == "high"
      assert_eventually_ok(fn -> turn!(turn.id).status == :completed end)
      assert_receive {:request, body}
      assert body["reasoning"]["effort"] == "high"

      # nothing given: the level in force stays
      {:ok, turn2} = Projects.send_message(thread, "say b")
      assert turn2.reasoning_effort == "high"
      assert_eventually_ok(fn -> turn!(turn2.id).status == :completed end)
      assert_receive {:request, body}
      assert body["reasoning"]["effort"] == "high"

      assert {:error, {:unknown_effort, "ultra"}} =
               Projects.send_message(thread, "say c", effort: "ultra")

      assert {:error, {:unknown_model, "nope"}} =
               Projects.send_message(thread, "say c", model: "nope")

      {:ok, turn3} = Projects.send_message(thread, "say c", model: model.slug)
      assert turn3.model_slug == model.slug
      assert thread!(thread.id).model_slug == model.slug
      assert_eventually_ok(fn -> turn!(turn3.id).status == :completed end)
      assert_receive {:request, body}
      assert body["model"] == "real-model"

      assert Enum.map(Projects.list_turns!(thread), & &1.id) == [turn.id, turn2.id, turn3.id]
    end
  end
end
