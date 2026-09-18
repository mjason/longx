defmodule Longx.WatchesTest do
  @moduledoc """
  Watches at runtime: files reconciled into rows, a run that sends to a
  session, the once-only file consumed, the budget, the Oban tick.
  Bypass plays the model for the session a watch wakes.
  """
  use Longx.DataCase, async: false
  use Oban.Testing, repo: Longx.Repo, engine: Oban.Engines.Lite, notifier: Oban.Notifiers.PG

  alias Longx.AI
  alias Longx.Agent.ThreadState
  alias Longx.Projects
  alias Longx.Projects.{Thread, Turn}
  alias Longx.Test.ResponsesFixture
  alias Longx.Watches
  alias Longx.Watches.Watch

  setup do
    Ash.bulk_destroy!(Watch, :destroy, %{}, authorize?: false)
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

    dir = Path.join(System.tmp_dir!(), "longx-watches-#{n}")
    File.mkdir_p!(Path.join(dir, ".longx/local/watches"))
    project = Projects.create_project!(%{name: "Watches #{n}", root_path: dir})

    on_exit(fn ->
      Longx.Test.Agents.stop_all!()
      File.rm_rf!(dir)
    end)

    %{bypass: bypass, dir: dir, project: project}
  end

  defp write!(dir, name, text) do
    path = Path.join(dir, ".longx/local/watches/#{name}.exs")
    File.write!(path, text)
    File.touch!(path, System.os_time(:second) + System.unique_integer([:positive, :monotonic]))
    path
  end

  defp model!(bypass, replies) do
    {:ok, queue} = Elixir.Agent.start_link(fn -> replies end)
    test = self()

    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, Jason.decode!(body)})
      chunks = Elixir.Agent.get_and_update(queue, fn [h | t] -> {h, t} end)

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

  @health """
  defmodule Health do
    use Longx.Agent.Watch
    every "*/5 * * * *"
    budget 1

    def run(ctx) do
      {code, out} = shell(ctx, "echo alive")
      log(ctx, String.trim(out))
      status = if code == 0, do: "ok", else: "fail"
      if status != ctx.state["status"], do: send(ctx, "main", "health is now \#{status}")
      {:ok, %{"status" => status}}
    end
  end
  """

  test "reconcile: files become rows with their next time; a broken head disables the row and is a notice; a gone file drops the row",
       %{dir: dir, project: project} do
    write!(dir, "health", @health)

    write!(dir, "broken", """
    defmodule Broken do
      use Longx.Agent.Watch
      every "whenever"
      def run(_), do: {:ok, %{}}
    end
    """)

    assert :ok = Watches.reconcile_project(project)

    assert [%Watch{name: "broken"} = broken, %Watch{name: "health"} = health] =
             project.id |> Watches.list_for_project!() |> Enum.sort_by(& &1.name)

    assert health.kind == :cron
    assert health.cron == "*/5 * * * *"
    assert health.enabled
    assert %DateTime{} = health.next_due_at
    assert health.path =~ "local/watches/health.exs"
    assert health.layer == :local
    assert health.budget_per_hour == 1

    refute broken.enabled
    assert broken.disabled_reason == :load_error
    assert broken.load_error =~ "cron"

    # the agent's prompt carries the notice
    loaded = Longx.Agent.Definition.Loader.load(dir, tag: project.id, trusted: false)
    assert Enum.any?(loaded.notices, &(&1 =~ "broken.exs"))

    # the file fixed: the row comes back
    write!(dir, "broken", String.replace(@health, "Health", "Broken"))
    assert :ok = Watches.reconcile_project(project)
    assert %Watch{enabled: true, disabled_reason: nil} = Watches.get_watch!(project.id, "broken")

    # the file gone: the row gone
    File.rm!(Path.join(dir, ".longx/local/watches/broken.exs"))
    assert :ok = Watches.reconcile_project(project)
    assert [%Watch{name: "health"}] = Watches.list_for_project!(project.id)
  end

  test "a run: the script's send wakes the session by address once idle, the state is kept, the row records the run; the budget stops a second send",
       %{bypass: bypass, dir: dir, project: project} do
    model!(bypass, [
      ResponsesFixture.assistant_message("looking"),
      ResponsesFixture.assistant_message("looking again")
    ])

    {:ok, main} = Projects.start_thread(project, handle: "main")
    :ok = Phoenix.PubSub.subscribe(Longx.PubSub, Longx.Notify.topic())
    write!(dir, "health", @health)
    :ok = Watches.reconcile_project(project)
    watch = Watches.get_watch!(project.id, "health")

    assert {:ok, %Watch{} = ran} = Watches.run(watch)
    assert ran.runs == 1
    assert ran.sends == 1
    assert ran.last_error == nil
    assert ran.state == %{"status" => "ok"}
    assert ran.last_output =~ "alive"
    assert ran.last_error == nil
    assert %DateTime{} = ran.last_run_at
    assert ran.last_duration_ms >= 0
    assert ran.running_since == nil
    assert DateTime.compare(ran.next_due_at, DateTime.utc_now()) == :gt

    # the session had a turn from the watch
    eventually(fn ->
      match?([%Turn{status: :completed, user_text: "（定时触发）health"}], Projects.list_turns!(main))
    end)

    assert %{items: items} = ThreadState.snapshot(main.kernel_thread_id)

    assert Enum.any?(items, fn item ->
             item["type"] == "userMessage" and item["from"] == "watch-health" and
               hd(item["content"])["text"] == "[agent watch-health] health is now ok"
           end)

    assert_receive {:notify, %{kind: "watch", title: title}}, 5_000
    assert title =~ "health"

    # nothing changed: the second run sends nothing
    assert {:ok, %Watch{runs: 2, sends: 1}} = Watches.run(ran)

    # the state forced back: the send is over budget (1/hour) → disabled, told
    {:ok, reset} = Watches.put_state(ran, %{"status" => "stale"})
    assert {:ok, %Watch{} = over} = Watches.run(reset)
    assert over.sends == 1
    refute over.enabled
    assert over.disabled_reason == :budget
    assert_receive {:notify, %{kind: "watch", title: title}}, 5_000
    assert title =~ "暂停"
  end

  test "send(:self) is the session named after the watch, started when there is none; a once watch is consumed with its file",
       %{bypass: bypass, dir: dir, project: project} do
    model!(bypass, [ResponsesFixture.assistant_message("on duty")])

    path =
      write!(dir, "nightly", """
      defmodule Nightly do
        use Longx.Agent.Watch
        once "2020-01-01T00:00:00Z"
        def run(ctx) do
          send(ctx, :self, "look at the logs")
          {:ok, %{}}
        end
      end
      """)

    :ok = Watches.reconcile_project(project)
    watch = Watches.get_watch!(project.id, "nightly")
    # due since 2020: nothing ahead, still runnable now
    assert watch.next_due_at == nil or
             DateTime.compare(watch.next_due_at, DateTime.utc_now()) != :gt

    assert {:ok, %Watch{} = done} = Watches.run(watch)
    refute done.enabled
    assert done.disabled_reason == :done
    refute File.exists?(path)

    assert {:ok, %Thread{handle: "watch-nightly", title: "⏰ nightly"} = own} =
             Projects.get_thread_by_handle(project.id, "watch-nightly")

    eventually(fn ->
      match?([%Turn{status: :completed}], Projects.list_turns!(own))
    end)

    # the next reconcile drops the row: the file is gone
    assert :ok = Watches.reconcile_project(project)
    assert [] = Watches.list_for_project!(project.id)
  end

  test "the tick queues a run for every due watch (unique per watch) and the runner runs it; a restart clears a run left marked running",
       %{dir: dir, project: project} do
    quiet =
      String.replace(@health, "do: send(ctx, \"main\", \"health is now \#{status}\")", "do: nil")

    write!(dir, "health", quiet)

    write!(
      dir,
      "later",
      quiet |> String.replace("*/5 * * * *", "0 0 1 1 *") |> String.replace("Health", "Later")
    )

    :ok = Watches.reconcile_project(project)

    # due now: next_due_at in the past
    {:ok, due} =
      Watches.put_due(Watches.get_watch!(project.id, "health"), ~U[2020-01-01 00:00:00Z])

    assert :ok = perform_job(Watches.Tick, %{})
    assert_enqueued(worker: Watches.Runner, args: %{"id" => due.id})

    refute_enqueued(
      worker: Watches.Runner,
      args: %{"id" => Watches.get_watch!(project.id, "later").id}
    )

    assert :ok = perform_job(Watches.Runner, %{"id" => due.id})
    assert %Watch{runs: 1} = Watches.get_watch!(project.id, "health")

    # a run left marked running by a previous boot is cleared
    {:ok, stuck} = Watches.mark_running(Watches.get_watch!(project.id, "health"))
    assert stuck.running_since
    assert :ok = Watches.settle_after_restart()
    assert %Watch{running_since: nil} = Watches.get_watch!(project.id, "health")
  end
end
