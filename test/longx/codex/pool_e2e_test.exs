defmodule Longx.Codex.PoolE2ETest do
  @moduledoc """
  The per-project pool with the real bundled codex: a project's thread runs
  on its own codex process in its own CODEX_HOME, the turn goes through the
  gateway, and a forced stop + resume keeps the thread usable.
  `mix test --include integration`.
  """
  use Longx.DataCase, async: false

  import Longx.Test.CodexHarness, only: [serve_endpoint!: 0]

  alias Longx.AI
  alias Longx.Codex.Pool
  alias Longx.Projects
  alias Longx.Test.ResponsesFixture

  @moduletag :integration
  @moduletag timeout: 180_000

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

    AI.create_model!(%{name: "M", upstream_id: "real-upstream", provider_id: provider.id})
    |> AI.make_default_model!()

    Bypass.expect(upstream, "POST", "/v1/responses", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn, length: 50_000_000)
      send(test_pid, {:upstream, Jason.decode!(raw)})

      conn =
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)

      Enum.reduce(ResponsesFixture.assistant_message("pooled hello"), conn, fn frame, conn ->
        {:ok, conn} = Plug.Conn.chunk(conn, frame)
        conn
      end)
    end)

    # the pool launches the real binary, pointed at this test's endpoint
    gateway_url = serve_endpoint!()
    old = Application.get_env(:longx, Pool, [])
    Application.put_env(:longx, Pool, connection: [home: [gateway_url: gateway_url]])

    dir = Path.join(System.tmp_dir!(), "longx-pool-e2e-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    project = Projects.create_project!(%{name: "Pooled", root_path: dir, sandbox: :read_only})
    Phoenix.PubSub.subscribe(Longx.PubSub, "codex:connection")

    on_exit(fn ->
      Longx.Test.PoolHelpers.stop_pool!([project.id])
      Application.put_env(:longx, Pool, old)
      File.rm_rf!(dir)
      File.rm_rf!(Pool.home_dir(project.id))
    end)

    %{project: project}
  end

  defp wait_until(fun, pred, attempts \\ 200) do
    value = fun.()

    cond do
      pred.(value) -> value
      attempts == 0 -> flunk("timed out waiting; last: #{inspect(value)}")
      true -> Process.sleep(100) && wait_until(fun, pred, attempts - 1)
    end
  end

  test "a project's thread runs on its own codex in its own home, through the gateway", %{
    project: project
  } do
    project_id = project.id
    {:ok, thread} = Projects.start_thread(project)
    assert_receive {:codex_connection, ^project_id, :ready}, 60_000

    home = Pool.home_dir(project_id)
    assert File.exists?(Path.join(home, "config.toml"))
    assert %{worker: %{os_pid: os_pid}} = Projects.codex_info(project)
    assert is_integer(os_pid)

    {:ok, turn} = Projects.send_message(thread, "hi")
    assert_receive {:upstream, %{"model" => "real-upstream"}}, 60_000
    done = wait_until(fn -> Ash.get!(Projects.Turn, turn.id) end, &(&1.status != :in_progress))
    assert done.status == :completed

    # stop it hard, send again: the thread is resumed on a fresh process
    :ok = Projects.stop_codex(project, force: true)
    assert_receive {:codex_connection, ^project_id, :down}, 10_000
    assert Pool.status(project_id) == :stopped

    {:ok, turn2} = Projects.send_message(thread, "again")
    assert_receive {:codex_connection, ^project_id, :ready}, 60_000
    assert_receive {:upstream, body}, 60_000
    # the history survived in the home's sqlite: the first exchange is replayed
    texts =
      for %{"type" => "message", "content" => c} <- body["input"], %{"text" => t} <- c, do: t

    assert Enum.any?(texts, &(&1 =~ "hi"))
    done2 = wait_until(fn -> Ash.get!(Projects.Turn, turn2.id) end, &(&1.status != :in_progress))
    assert done2.status == :completed
  end
end
