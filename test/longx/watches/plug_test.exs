defmodule Longx.Watches.PlugTest do
  @moduledoc "The Watches plug: the agent's tools over its watch files, and what the prompt tells it."
  use Longx.DataCase, async: false

  alias Longx.AI
  alias Longx.Projects
  alias Longx.Projects.{Thread, Turn}
  alias Longx.Test.ResponsesFixture
  alias Longx.Watches

  setup do
    Ash.bulk_destroy!(Watches.Watch, :destroy, %{}, authorize?: false)
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
        provider_id: provider.id
      })

    AI.make_default_model!(model)

    dir = Path.join(System.tmp_dir!(), "longx-watchplug-#{n}")
    File.mkdir_p!(Path.join(dir, ".longx/local/watches"))
    project = Projects.create_project!(%{name: "WatchPlug #{n}", root_path: dir})

    on_exit(fn ->
      Longx.Test.Agents.stop_all!()
      File.rm_rf!(dir)
    end)

    %{bypass: bypass, dir: dir, project: project}
  end

  defp script!(bypass, replies) do
    {:ok, queue} = Elixir.Agent.start_link(fn -> replies end)
    test = self()

    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, Jason.decode!(body)})

      chunks =
        case Elixir.Agent.get_and_update(queue, fn [h | t] -> {h, t} end) do
          fun when is_function(fun, 0) -> fun.()
          chunks -> chunks
        end

      conn =
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)

      Enum.reduce(chunks, conn, fn chunk, c ->
        {:ok, c} = Plug.Conn.chunk(c, chunk)
        c
      end)
    end)
  end

  defp eventually(fun, tries \\ 50) do
    if fun.() do
      :ok
    else
      if tries == 0, do: flunk("condition never held")
      Process.sleep(50)
      eventually(fun, tries - 1)
    end
  end

  defp outputs(body),
    do: for(%{"type" => "function_call_output", "output" => o} <- body["input"], do: o)

  test "watch_list, watch_run (a dry run), watch_enable, wait_until; the prompt teaches the file",
       %{bypass: bypass, dir: dir, project: project} do
    health = """
    defmodule Health do
      use Longx.Agent.Watch
      every "*/10 * * * *"
      def run(ctx) do
        log(ctx, "checked")
        send(ctx, "main", "all quiet")
        {:ok, %{}}
      end
    end
    """

    script!(bypass, [
      ResponsesFixture.function_call("watch_list", nil, %{}),
      # "the agent writes the file" (apply_patch in real life)
      fn ->
        File.write!(Path.join(dir, ".longx/local/watches/health.exs"), health)
        ResponsesFixture.function_call("watch_list", nil, %{})
      end,
      ResponsesFixture.function_call("watch_run", nil, %{"name" => "health"}),
      ResponsesFixture.function_call("watch_enable", nil, %{
        "name" => "health",
        "enabled" => false
      }),
      ResponsesFixture.function_call("wait_until", nil, %{
        "at" => "2030-01-01T09:00:00+08:00",
        "message" => "check whether the deploy finished; the \"canary\" first"
      }),
      ResponsesFixture.assistant_message("I will look again at nine.")
    ])

    {:ok, thread} = Projects.start_thread(project, handle: "main")
    {:ok, turn} = Projects.send_message(thread, "set up a health watch")
    eventually(fn -> Ash.get!(Turn, turn.id).status == :completed end)

    assert_receive {:request, first}
    assert first["instructions"] =~ "# Watches"
    assert first["instructions"] =~ ".longx/local/watches/<name>.exs"
    assert first["instructions"] =~ ".longx/shared/watches/<name>.exs"
    assert first["instructions"] =~ "wait_until"
    assert Enum.any?(first["tools"], &(&1["name"] == "watch_list"))

    assert_receive {:request, second}
    assert [empty] = outputs(second)
    assert empty =~ "no watch"

    assert_receive {:request, third}
    assert [_, listed] = outputs(third)
    assert listed =~ "health"
    assert listed =~ "*/10 * * * *"
    assert listed =~ "next"

    assert_receive {:request, fourth}
    assert [_, _, dry] = outputs(fourth)
    assert dry =~ "checked"
    assert dry =~ "would send to \"main\": all quiet"
    assert dry =~ "{:ok, %{}}"
    # a dry run delivers nothing
    assert [%Turn{}] = Projects.list_turns!(thread)

    assert_receive {:request, fifth}
    assert [_, _, _, switched] = outputs(fifth)
    assert switched =~ "off"

    assert %Watches.Watch{enabled: false, disabled_reason: :by_person} =
             Watches.get_watch!(project.id, "health")

    assert_receive {:request, sixth}
    assert [_, _, _, _, waited] = outputs(sixth)
    assert waited =~ "2030-01-01"
    assert waited =~ "end your turn"

    # the file it wrote: a once watch that sends to this session
    [path] = Path.wildcard(Path.join(dir, ".longx/local/watches/wait-*.exs"))
    text = File.read!(path)
    assert text =~ ~s(once "2030-01-01T09:00:00+08:00")
    assert text =~ ~s(send(ctx, "main", )
    assert text =~ "canary"

    assert %Watches.Watch{kind: :once, enabled: true} =
             Watches.get_watch!(project.id, Path.basename(path, ".exs"))
  end

  test "wait_until refuses an instant already past and says what time it is (the agent has no clock: it once asked for 11:00 at 17:17)",
       %{bypass: bypass, dir: dir, project: project} do
    script!(bypass, [
      ResponsesFixture.function_call("wait_until", nil, %{
        "at" => "2020-01-01T09:00:00+08:00",
        "message" => "look again"
      }),
      ResponsesFixture.assistant_message("ok")
    ])

    {:ok, thread} = Projects.start_thread(project, handle: "main")
    {:ok, turn} = Projects.send_message(thread, "wait a bit")
    eventually(fn -> Ash.get!(Turn, turn.id).status == :completed end)

    assert_receive {:request, _first}
    assert_receive {:request, second}
    assert [refused] = outputs(second)
    assert refused =~ "in the past"
    assert refused =~ "now is 20"
    assert [] == Path.wildcard(Path.join(dir, ".longx/local/watches/wait-*.exs"))
  end

  test "wait_until puts the session on duty: it asked to be woken, so its own watch may wake it (a plain conversation's alarm was once refused as off duty, silently)",
       %{bypass: bypass, dir: dir, project: project} do
    script!(bypass, [
      ResponsesFixture.function_call("wait_until", nil, %{
        "at" => "2030-01-01T09:00:00+08:00",
        "message" => "look again"
      }),
      ResponsesFixture.assistant_message("later")
    ])

    {:ok, thread} = Projects.start_thread(project)
    refute Projects.on_duty?(thread)
    {:ok, turn} = Projects.send_message(thread, "wait a bit")
    eventually(fn -> Ash.get!(Turn, turn.id).status == :completed end)

    assert_receive {:request, _first}
    assert_receive {:request, second}
    assert [written] = outputs(second)
    assert written =~ "on duty"
    assert %Thread{on_duty: true} = thread = Ash.get!(Thread, thread.id)
    assert Projects.on_duty?(thread)
    [path] = Path.wildcard(Path.join(dir, ".longx/local/watches/wait-*.exs"))
    assert File.read!(path) =~ ~s(send(ctx, "#{Projects.agent_name(thread)}", )
  end
end
