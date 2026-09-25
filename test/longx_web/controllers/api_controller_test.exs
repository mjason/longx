defmodule LongxWeb.ApiControllerTest do
  # A page's address with /api in front answers that conversation as JSON —
  # whatever the client says it accepts (an agent's fetch tool asks for HTML).
  use LongxWeb.ConnCase, async: false

  alias Longx.Projects

  setup do
    n = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "longx-api-#{n}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, project} = Projects.create_project(%{name: "Api #{n}", root_path: root})

    {:ok, thread} =
      Projects.create_thread(%{
        kernel_thread_id: "native_api_#{n}",
        project_id: project.id,
        cwd: root
      })

    %{project: project, thread: thread}
  end

  test "a thread and a project as JSON; an unknown one is a JSON 404", %{
    conn: conn,
    project: project,
    thread: thread
  } do
    conn =
      conn
      |> put_req_header("accept", "text/html")
      |> get("/api/p/#{project.slug}/t/#{thread.id}")

    assert ["application/json" <> _] = get_resp_header(conn, "content-type")
    assert %{"thread" => %{"id" => id}, "turns" => %{"total" => 0}} = json_response(conn, 200)
    assert id == thread.id

    conn = build_conn() |> get("/api/p/#{project.slug}?x=1")
    assert %{"threads" => [%{"id" => ^id, "api" => "http://" <> _}]} = json_response(conn, 200)

    conn = build_conn() |> get("/api/p/#{project.slug}/t/#{Ash.UUID.generate()}")
    assert %{"error" => "not found"} = json_response(conn, 404)
  end

  test "?turns= and ?full= reach the report", %{conn: conn, project: project, thread: thread} do
    conn = get(conn, "/api/p/#{project.slug}/t/#{thread.id}?turns=all&full=1")
    assert %{"turns" => %{"shown" => 0}} = json_response(conn, 200)
  end
end
