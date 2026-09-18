defmodule LongxWeb.HooksControllerTest do
  @moduledoc "POST /hooks/:token: a webhook watch's run queued with the body as its payload."
  use LongxWeb.ConnCase, async: false
  use Oban.Testing, repo: Longx.Repo, engine: Oban.Engines.Lite, notifier: Oban.Notifiers.PG

  alias Longx.Projects
  alias Longx.Watches
  alias Longx.Watches.Watch

  setup do
    Ash.bulk_destroy!(Watch, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(Projects.Project, :destroy, %{}, authorize?: false)
    n = System.unique_integer([:positive])
    dir = Path.join(System.tmp_dir!(), "longx-hooks-#{n}")
    File.mkdir_p!(Path.join(dir, ".longx/local/watches"))
    on_exit(fn -> File.rm_rf!(dir) end)
    project = Projects.create_project!(%{name: "Hooks #{n}", root_path: dir})

    File.write!(Path.join(dir, ".longx/local/watches/deploy.exs"), """
    defmodule Deploy do
      use Longx.Agent.Watch
      webhook true
      def run(ctx), do: {:ok, %{last: ctx.payload}}
    end
    """)

    :ok = Watches.reconcile_project(project)
    %{watch: Watches.get_watch!(project.id, "deploy")}
  end

  test "a known token queues the run with the JSON body; an unknown one is 404; a disabled watch is 409",
       %{conn: conn, watch: watch} do
    assert is_binary(watch.webhook_token)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/hooks/#{watch.webhook_token}", ~s({"status":"deployed","sha":"abc"}))

    assert response(conn, 202) =~ "queued"

    assert_enqueued(
      worker: Watches.Runner,
      args: %{"id" => watch.id, "payload" => %{"status" => "deployed", "sha" => "abc"}}
    )

    assert post(build_conn(), "/hooks/nope") |> response(404)

    {:ok, _} = Watches.set_switch(watch, false)
    assert post(build_conn(), "/hooks/#{watch.webhook_token}") |> response(409)
  end

  test "a text body is the payload as a string, clipped", %{conn: conn, watch: watch} do
    conn =
      conn
      |> put_req_header("content-type", "text/plain")
      |> post("/hooks/#{watch.webhook_token}", String.duplicate("x", 10_000))

    assert response(conn, 202)
    assert [%{args: %{"payload" => payload}}] = all_enqueued(worker: Watches.Runner)
    assert is_binary(payload) and byte_size(payload) == 8_192
  end
end
