defmodule Longx.Projects.NativeEngineTest do
  use Longx.DataCase, async: false

  alias Longx.Agent
  alias Longx.Agent.Transcript
  alias Longx.AI
  alias Longx.Codex.ThreadState
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
      Projects.create_project!(%{name: "Native #{n}", root_path: dir, engine: :native})

    on_exit(fn ->
      for t <- Ash.read!(Thread, authorize?: false) do
        Agent.stop(t.codex_thread_id)
        ThreadState.stop(t.codex_thread_id)
        ThreadState.Store.delete(t.codex_thread_id)
      end

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

  test "a native project starts threads on the kernel, not on codex", %{
    project: project,
    model: model
  } do
    {:ok, thread} = Projects.start_thread(project, effort: "high")

    assert "native_" <> _ = thread.codex_thread_id
    assert thread.model_slug == nil
    assert thread.reasoning_effort == "high"
    assert Agent.whereis(thread.codex_thread_id)
    assert Longx.Codex.Pool.running() == []

    assert {:error, _} = Projects.start_thread(project, model: "nope")
    assert {:error, _} = Projects.start_thread(project, model: model.slug, effort: "ultra")
  end

  test "a message is a turn the Tracker completes with its git bookmarks", %{
    bypass: bypass,
    project: project,
    dir: dir
  } do
    script!(bypass, [ResponsesFixture.assistant_message("hi back")])
    {:ok, thread} = Projects.start_thread(project)
    File.write!(Path.join(dir, "a.txt"), "v2\n")

    {:ok, turn} = Projects.send_message(thread, "hello")
    assert turn.status == :in_progress
    assert turn.commit_before
    assert thread!(thread.id).status == :active

    assert_eventually_ok(fn -> turn!(turn.id).status == :completed end)
    turn = turn!(turn.id)
    assert turn.commit_after == turn.commit_before
    assert thread!(thread.id).status == :idle
    assert thread!(thread.id).preview == "hello"

    assert_receive {:request, body}
    assert body["reasoning"]["effort"] == "low"
    assert [_, %{kind: :agent_message}] = Transcript.items!(thread.codex_thread_id)

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
    assert {:ok, %{codex_turn_id: id}} = Projects.steer_message(thread, "and this")
    assert id == turn.codex_turn_id
    assert {:error, :turn_in_progress} = Projects.send_message(thread, "no")
    send(h1, :go)
    assert_eventually_ok(fn -> turn!(turn.id).status == :completed end)

    {:ok, turn2} = Projects.send_message(thread, "second")
    assert_receive {:held, _h2}, 5_000
    Bypass.pass(bypass)
    assert :ok = Projects.interrupt_turn(thread, turn2.codex_turn_id)
    assert_eventually_ok(fn -> turn!(turn2.id).status == :interrupted end)

    {:ok, turn3} = Projects.send_message(thread, "third")
    assert_receive {:held, _h3}, 5_000
    assert {:ok, %{text: "third"}} = Projects.retract_turn(thread, turn3)
    assert turn!(turn3.id).status == :reverted
    assert thread!(thread.id).status == :idle

    refute Enum.any?(
             Transcript.items!(thread.codex_thread_id),
             &(&1.turn_id == turn3.codex_turn_id)
           )
  end

  test "opening a thread after a restart starts its agent again; deleting it drops the log", %{
    bypass: bypass,
    project: project
  } do
    script!(bypass, [ResponsesFixture.assistant_message("kept")])
    {:ok, thread} = Projects.start_thread(project)
    {:ok, turn} = Projects.send_message(thread, "remember")
    assert_eventually_ok(fn -> turn!(turn.id).status == :completed end)

    :ok = Agent.stop(thread.codex_thread_id)
    :ok = ThreadState.stop(thread.codex_thread_id)
    :ok = ThreadState.Store.delete(thread.codex_thread_id)

    assert {:ok, id} = Projects.host_thread(thread.codex_thread_id)
    assert id == thread.codex_thread_id
    assert Agent.whereis(id)
    assert length(ThreadState.snapshot(id).items) == 2

    assert :ok = Projects.delete_thread(thread)
    assert Transcript.items!(id) == []
    refute Agent.whereis(id)
  end

  test "skills and the file search need no codex on a native project", %{
    project: project,
    dir: dir
  } do
    File.mkdir_p!(Path.join(dir, "lib/deep"))
    File.write!(Path.join(dir, "lib/deep/math_helper.ex"), "")
    File.write!(Path.join(dir, "notes.md"), "")

    assert {:ok, []} = Projects.list_skills(project)

    assert {:ok, [%{path: "lib/deep/math_helper.ex", file_name: "math_helper.ex"}]} =
             Projects.search_files(project, "mhelp")

    assert {:ok, [%{path: "a.txt"} | _]} = Projects.search_files(project, "a")
    assert {:ok, []} = Projects.search_files(project, "zzz")
    assert Longx.Codex.Pool.running() == []
  end

  test "what the kernel does not do yet is refused, not attempted", %{project: project} do
    {:ok, thread} = Projects.start_thread(project)
    assert {:error, :not_supported} = Projects.compact_thread(thread)
    assert {:error, :not_supported} = Projects.review_thread(thread, :uncommitted)
  end
end
