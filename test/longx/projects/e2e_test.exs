defmodule Longx.Projects.E2ETest do
  @moduledoc "Real codex: a project with its own model, a turn with git bookmarks, and a restore. `mix test --include integration`."
  use Longx.DataCase, async: false

  import Longx.Test.CodexHarness

  alias Longx.AI
  alias Longx.Git
  alias Longx.Projects
  alias Longx.Test.ResponsesFixture

  @moduletag :integration
  @moduletag timeout: 120_000

  setup do
    for r <- [
          Projects.Turn,
          Projects.Thread,
          Projects.Project,
          AI.Model,
          AI.Provider,
          AI.SearchProvider
        ] do
      Ash.bulk_destroy!(r, :destroy, %{}, authorize?: false)
    end

    upstream = Bypass.open()
    test_pid = self()

    provider =
      AI.create_provider!(%{
        name: "Fake",
        slug: "fake-#{System.unique_integer([:positive])}",
        base_url: "http://localhost:#{upstream.port}/v1",
        api_key: "sk-fake"
      })

    AI.create_model!(%{
      name: "Default",
      upstream_id: "default-upstream",
      slug: "default-model",
      provider_id: provider.id
    })
    |> AI.make_default_model!()

    project_model =
      AI.create_model!(%{
        name: "Project",
        upstream_id: "project-upstream",
        slug: "project-model",
        provider_id: provider.id,
        context_window: 42_000
      })

    Bypass.expect(upstream, "POST", "/v1/responses", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn, length: 50_000_000)
      send(test_pid, {:upstream_model, Jason.decode!(raw)["model"]})

      conn =
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)

      Enum.reduce(ResponsesFixture.assistant_message("done"), conn, fn f, c ->
        {:ok, c} = Plug.Conn.chunk(c, f)
        c
      end)
    end)

    gateway_url = serve_endpoint!()
    home = prepare_home!(gateway_url)
    conn = start_connection!(home)

    dir = Path.join(System.tmp_dir!(), "longx-pe2e-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    :ok = Git.init(dir)
    File.write!(Path.join(dir, "README.md"), "hello\n")
    {:ok, base} = Git.commit_all(dir, "base")

    project =
      Projects.create_project!(%{
        name: "E2E",
        root_path: dir,
        model_id: project_model.id,
        approval_policy: :never,
        sandbox: :read_only
      })

    %{conn: conn, project: project, dir: dir, base: base}
  end

  test "project model reaches the upstream by slug; turn gets bookmarks; files can be restored",
       %{conn: conn, project: project, dir: dir, base: base} do
    {:ok, thread} = Projects.start_thread(project, conn: conn)
    assert thread.model_slug == "project-model"
    Longx.Codex.Thread.subscribe(thread.codex_thread_id)

    # the user edited something before asking → committed by the preflight
    File.write!(Path.join(dir, "README.md"), "hello edited\n")
    {:ok, turn} = Projects.send_message(thread, "hi", conn: conn)
    refute turn.commit_before == base
    assert %{clean?: true} = Git.status(dir)

    assert_receive {:codex, _, "turn/completed", _}, 60_000
    # codex sent our slug, the gateway mapped it to the provider's id
    assert_receive {:upstream_model, "project-upstream"}, 5_000

    done = wait_until(fn -> Ash.get!(Projects.Turn, turn.id) end, &(&1.status != :in_progress))
    assert done.status == :completed
    assert done.commit_after == turn.commit_before

    # "the agent" left changes; going back to before the turn is a confirmed action
    File.write!(Path.join(dir, "README.md"), "agent broke it\n")
    {:ok, proposal} = Projects.restore_proposal(done)
    assert proposal.dirty_now?
    {:ok, %{safety_commit: safety}} = Projects.restore_files(done, confirm: true)
    assert is_binary(safety)
    assert File.read!(Path.join(dir, "README.md")) == "hello edited\n"
  end

  test "redo a turn with another model: codex history is reverted, the new model is used", %{
    conn: conn,
    project: project
  } do
    {:ok, thread} = Projects.start_thread(project, conn: conn)
    Longx.Codex.Thread.subscribe(thread.codex_thread_id)

    {:ok, t1} = Projects.send_message(thread, "first question", conn: conn)
    assert_receive {:codex, _, "turn/completed", _}, 60_000
    wait_until(fn -> Ash.get!(Projects.Turn, t1.id) end, &(&1.status != :in_progress))
    {:ok, t2} = Projects.send_message(thread, "second question", conn: conn)
    assert_receive {:codex, _, "turn/completed", _}, 60_000
    wait_until(fn -> Ash.get!(Projects.Turn, t2.id) end, &(&1.status != :in_progress))
    assert_receive {:upstream_model, "project-upstream"}
    assert_receive {:upstream_model, "project-upstream"}

    {:ok, redo} =
      Projects.redo_turn(t2, model: "default-model", text: "second question, redone", conn: conn)

    assert_receive {:codex, _, "thread/reverted", %{"turnIds" => [_]}}, 5_000
    assert_receive {:codex, _, "turn/completed", _}, 60_000
    # the redo went to the other model, with a history that no longer has the reverted turn
    assert_receive {:upstream_model, "default-upstream"}, 5_000
    done = wait_until(fn -> Ash.get!(Projects.Turn, redo.id) end, &(&1.status != :in_progress))
    assert done.status == :completed
    assert Ash.get!(Projects.Turn, t2.id).status == :reverted

    {:ok, read} =
      Longx.Codex.Connection.request(conn, "thread/read", %{
        "threadId" => thread.codex_thread_id,
        "includeTurns" => true
      })

    assert Enum.map(read["thread"]["turns"], & &1["id"]) == [t1.codex_turn_id, redo.codex_turn_id]

    assert Longx.Codex.Thread.snapshot(thread.codex_thread_id).items
           |> Enum.map(& &1["turnId"])
           |> Enum.uniq() == [t1.codex_turn_id, redo.codex_turn_id]
  end

  defp wait_until(fetch, pred, attempts \\ 100) do
    value = fetch.()

    cond do
      pred.(value) -> value
      attempts == 0 -> flunk("timed out waiting; last: #{inspect(value)}")
      true -> Process.sleep(50) && wait_until(fetch, pred, attempts - 1)
    end
  end
end
