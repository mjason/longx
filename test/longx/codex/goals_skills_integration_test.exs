defmodule Longx.Codex.GoalsSkillsIntegrationTest do
  @moduledoc """
  codex's goal mode, skills and the fs watch against the real binary through
  our gateway (a `Bypass` plays the model): a goal set from outside makes
  codex start turns by itself until the model marks it complete; a skill in
  the working directory is listed and, named as a skill input, its SKILL.md
  reaches the model; a watched root reports a change.
  """
  use Longx.DataCase, async: false

  import Longx.Test.CodexHarness

  alias Longx.Codex.{Connection, Thread, ThreadState}
  alias Longx.Test.ResponsesFixture

  @moduletag :integration

  setup do
    Ash.bulk_destroy!(Longx.AI.Model, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(Longx.AI.Provider, :destroy, %{}, authorize?: false)
    bypass = Bypass.open()

    {:ok, provider} =
      Longx.AI.create_provider(%{
        name: "Fake",
        slug: "fake",
        base_url: "http://localhost:#{bypass.port}/v1",
        api_key: "k"
      })

    {:ok, model} =
      Longx.AI.create_model(%{
        name: "Fake",
        upstream_id: "fake-model",
        provider_id: provider.id,
        context_window: 128_000
      })

    {:ok, _} = Longx.AI.make_default_model(model)
    %{bypass: bypass, gateway_url: serve_endpoint!()}
  end

  defp send_sse(conn, frames) do
    conn =
      conn |> Plug.Conn.put_resp_content_type("text/event-stream") |> Plug.Conn.send_chunked(200)

    Enum.reduce(frames, conn, fn frame, conn ->
      {:ok, conn} = Plug.Conn.chunk(conn, frame)
      conn
    end)
  end

  defp thread!(conn, home) do
    params = Thread.start_params(cwd: home.dir, sandbox: :workspace_write, tools: [])
    {:ok, %{"thread" => %{"id" => thread_id}}} = Connection.request(conn, "thread/start", params)
    {:ok, _} = ThreadState.ensure(thread_id)
    :ok = Thread.subscribe(thread_id)
    thread_id
  end

  test "goal mode: a goal set from outside makes codex start turns on its own; the model's update_goal ends it",
       %{bypass: bypass, gateway_url: gateway_url} do
    test_pid = self()

    # first request: report; the second (a continuation) completes the goal
    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      send(test_pid, {:request, body})
      names = for t <- body["tools"], do: t["name"]
      assert "update_goal" in names and "create_goal" in names

      cond do
        Enum.any?(body["input"], &(&1["type"] == "function_call_output")) ->
          send_sse(conn, ResponsesFixture.assistant_message("goal done"))

        Enum.any?(body["input"], &(is_binary(&1["content"]) and &1["content"] =~ "goal")) or
            Enum.any?(body["input"], fn i ->
              is_list(i["content"]) and
                  Enum.any?(
                    i["content"],
                    &(is_binary(&1["text"]) and &1["text"] =~ "thread goal")
                  )
            end) ->
          send_sse(
            conn,
            ResponsesFixture.function_call("update_goal", nil, %{status: "complete"})
          )

        true ->
          send_sse(conn, ResponsesFixture.assistant_message("working"))
      end
    end)

    home = prepare_home!(gateway_url)
    conn = start_connection!(home)
    thread_id = thread!(conn, home)

    assert {:ok, %{"objective" => "finish the thing", "status" => "active"}} =
             Thread.set_goal(thread_id, objective: "finish the thing", conn: conn)

    assert_receive {:codex, _, "thread/goal/updated", %{"goal" => %{"status" => "active"}}},
                   10_000

    # codex starts a turn nobody asked for
    assert_receive {:codex, _, "turn/started", %{"turn" => %{"id" => _}}}, 30_000

    assert_receive {:codex, _, "thread/goal/updated", %{"goal" => %{"status" => "complete"}}},
                   60_000

    assert_receive {:codex, _, "turn/completed", _}, 30_000
    assert Thread.snapshot(thread_id).goal["status"] == "complete"

    # the continuation prompt named the objective
    assert_receive {:request, %{"input" => input}} when length(input) > 1
    texts = for %{"content" => c} <- input, is_list(c), %{"text" => t} <- c, do: t
    assert Enum.any?(texts, &(&1 =~ "finish the thing"))

    # complete: no further turn
    refute_receive {:codex, _, "turn/started", _}, 3_000
    assert {:ok, true} = Thread.clear_goal(thread_id, conn: conn)
    assert_receive {:codex, _, "thread/goal/cleared", _}, 5_000
  end

  test "skills: a SKILL.md under .agents/skills is listed; named as a skill input its text reaches the model",
       %{bypass: bypass, gateway_url: gateway_url} do
    test_pid = self()

    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, Jason.decode!(raw)})
      send_sse(conn, ResponsesFixture.assistant_message("ok"))
    end)

    home = prepare_home!(gateway_url)
    skill_dir = Path.join(home.dir, ".agents/skills/tidy")
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      "---\nname: tidy\ndescription: Tidy the code before a commit\n---\nAlways run the formatter first, THE-SECRET-STEP.\n"
    )

    conn = start_connection!(home)
    assert {:ok, skills} = Thread.list_skills(home.dir, conn: conn)

    assert %{
             name: "tidy",
             description: "Tidy the code before a commit",
             path: path,
             enabled: true
           } =
             Enum.find(skills, &(&1.name == "tidy"))

    assert path == Path.join(skill_dir, "SKILL.md")

    thread_id = thread!(conn, home)

    {:ok, _} =
      Thread.send(thread_id, "use $tidy", skills: [%{name: "tidy", path: path}], conn: conn)

    assert_receive {:codex, _, "turn/completed", _}, 60_000
    assert_receive {:request, %{"input" => input}}
    assert inspect(input) =~ "THE-SECRET-STEP"
  end

  test "fs/watch on the working directory: a file written there is reported as fs/changed",
       %{bypass: bypass, gateway_url: gateway_url} do
    Bypass.stub(bypass, "POST", "/v1/responses", fn conn ->
      send_sse(conn, ResponsesFixture.assistant_message("ok"))
    end)

    home = prepare_home!(gateway_url)
    conn = start_connection!(home)
    Phoenix.PubSub.subscribe(Longx.PubSub, "codex:server")

    assert {:ok, %{"path" => _}} =
             Connection.request(conn, "fs/watch", %{"watchId" => "w1", "path" => home.dir})

    File.write!(Path.join(home.dir, "changed.txt"), "x")

    assert_receive {:codex_server, _, "fs/changed",
                    %{"watchId" => "w1", "changedPaths" => paths}},
                   15_000

    assert Enum.any?(paths, &String.ends_with?(&1, "changed.txt"))
  end
end
