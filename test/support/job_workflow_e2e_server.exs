# Opt-in, local-only live UI verification with an isolated database and job store.
# MIX_ENV=test LONGX_JOB_E2E_DIR=.longx/local/artifacts/job-workflow-e2e/run-...
# LONGX_JOB_E2E_PORT=17918 mix run --no-start test/support/job_workflow_e2e_server.exs
unless Mix.env() == :test, do: raise("requires MIX_ENV=test")

defmodule Longx.Test.JobWorkflowE2EModel do
  import Plug.Conn
  def init(opts), do: opts

  def call(%{method: "POST", request_path: "/v1/responses"} = conn, opts) do
    {:ok, body, conn} = read_body(conn, length: 2_000_000)
    input = Jason.decode!(body)["input"]

    {last, index} =
      input
      |> Enum.with_index()
      |> Enum.filter(fn {item, _} -> item["role"] == "user" end)
      |> List.last()

    content = last["content"]

    text =
      if is_binary(content), do: content, else: Enum.map_join(content, &Map.get(&1, "text", ""))

    since = Enum.drop(input, index + 1)
    names = Enum.map(since, & &1["name"])
    fixture = Longx.Test.ResponsesFixture

    chunks =
      cond do
        not (String.contains?(text, "CONFIRM_RESULT") or String.contains?(text, "继续检查待处理的任务结果")) ->
          fixture.assistant_message("JOB_WORKFLOW_INCOMPLETE: stopped work remains incomplete.")

        "review_job" in names ->
          fixture.assistant_message("JOB_WORKFLOW_CONFIRMED: the result has been checked.")

        "job_output" in names ->
          unless Enum.any?(
                   since,
                   &String.contains?(to_string(&1["output"] || ""), "verified-live-result")
                 ),
                 do: raise("the actual job output was not received")

          fixture.function_call("review_job", nil, %{
            "name" => "ready-result",
            "run" => opts[:run],
            "outcome" => "complete",
            "note" => "Live E2E checked the actual verified-live-result output"
          })

        true ->
          fixture.function_call("job_output", nil, %{"name" => "ready-result"})
      end

    conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)

    Enum.reduce(chunks, conn, fn chunk, conn ->
      {:ok, conn} = Plug.Conn.chunk(conn, chunk)
      conn
    end)
  end

  def call(conn, _), do: send_resp(conn, 404, "local test fixture only")
end

root = System.fetch_env!("LONGX_JOB_E2E_DIR") |> Path.expand()
artifacts = Path.expand(".longx/local/artifacts")

case Path.relative_to(root, artifacts) |> Path.split() do
  ["job-workflow-e2e", "run-" <> suffix] when byte_size(suffix) > 0 -> :ok
  _ -> raise("use a fresh scoped job-workflow-e2e/run-... artifact directory")
end

database = Path.join(root, "e2e.db")
if File.exists?(database), do: raise("refusing an existing database")
File.mkdir_p!(Path.join(root, "project"))
port = System.fetch_env!("LONGX_JOB_E2E_PORT") |> String.to_integer()
unless port in 1024..65_535, do: raise("invalid test port")

Application.put_env(
  :longx,
  Longx.Repo,
  Application.fetch_env!(:longx, Longx.Repo)
  |> Keyword.put(:database, database)
  |> Keyword.put(:pool, DBConnection.ConnectionPool)
)

Application.put_env(
  :longx,
  LongxWeb.Endpoint,
  Application.fetch_env!(:longx, LongxWeb.Endpoint)
  |> Keyword.merge(
    server: true,
    http: [ip: {127, 0, 0, 1}, port: port],
    url: [host: "127.0.0.1", port: port],
    check_origin: ["http://127.0.0.1:#{port}"],
    code_reloader: false,
    watchers: []
  )
)

Application.put_env(:longx, LongxWeb.Vite,
  dev_server: nil,
  manifest: {:priv, "static/assets/.vite/manifest.json"}
)

for {module, options} <- [
      {Longx.Jobs, [dir: Path.join(root, "jobs")]},
      {Longx.Projects.Attachments, [dir: Path.join(root, "attachments")]},
      {Longx.Agent.Knowledge, [global_dir: Path.join(root, "knowledge")]},
      {Longx.Tls, [dir: Path.join(root, "tls"), tool_dir: Path.join(root, "cert-tool")]},
      {Longx.Browser, [dir: Path.join(root, "browser"), executable: "/nonexistent/test-browser"]},
      {Longx.Computer, [dir: Path.join(root, "computer")]},
      {Longx.Upgrade, [tick: nil]}
    ] do
  Application.put_env(
    :longx,
    module,
    Keyword.merge(Application.get_env(:longx, module, []), options)
  )
end

Application.put_env(:sentry, :dsn, nil)

Application.put_env(
  :longx,
  Oban,
  Application.fetch_env!(:longx, Oban) |> Keyword.put(:testing, :manual)
)

System.delete_env("RELEASE_NAME")
{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Application.ensure_all_started(:ecto_sqlite3)
:ok = Longx.Migrator.migrate(database: database)
{:ok, _} = Application.ensure_all_started(:longx)

project =
  Longx.Projects.create_project!(%{
    name: "Job workflow live test",
    root_path: Path.join(root, "project")
  })

thread =
  Longx.Projects.create_thread!(%{
    project_id: project.id,
    kernel_thread_id: "native_job_e2e",
    cwd: project.root_path
  })

{:ok, ready} =
  Longx.Jobs.start(thread.kernel_thread_id, "ready-result", "echo verified-live-result",
    cwd: project.root_path,
    notify: false,
    purpose: "wait"
  )

{:ok, _} = Longx.Jobs.wait(thread.kernel_thread_id, ready.name, 5_000)

{:ok, model_server} =
  Bandit.start_link(
    plug: {Longx.Test.JobWorkflowE2EModel, run: ready.run},
    ip: {127, 0, 0, 1},
    port: 0
  )

{:ok, {_ip, model_port}} = ThousandIsland.listener_info(model_server)

provider =
  Longx.AI.create_provider!(%{
    name: "Local job test",
    slug: "job-e2e",
    base_url: "http://127.0.0.1:#{model_port}/v1",
    api_key: "local-test-not-a-provider-secret"
  })

model =
  Longx.AI.create_model!(%{
    name: "Local job test",
    slug: "job-e2e",
    upstream_id: "job-e2e",
    provider_id: provider.id
  })

{:ok, _} = Longx.AI.set_default_model(model.slug)

{:ok, waiting} =
  Longx.Jobs.start(
    thread.kernel_thread_id,
    "running-check",
    "echo verification-started; sleep 180",
    cwd: project.root_path,
    purpose: "wait"
  )

{:ok, service} =
  Longx.Jobs.start(thread.kernel_thread_id, "dev-service", "echo service-started; sleep 180",
    cwd: project.root_path,
    notify: false,
    purpose: "background"
  )

identity = %{
  test_only: true,
  kind: "job-workflow",
  root: root,
  url: "http://127.0.0.1:#{port}",
  project: %{id: project.id, slug: project.slug},
  thread: %{id: thread.id, kernel: thread.kernel_thread_id},
  ready: ready,
  waiting: waiting,
  service: service,
  model: model.slug
}

path = Path.join(root, "runner.json")
File.write!(path, Jason.encode!(identity, pretty: true))
IO.puts("JOB_WORKFLOW_E2E_READY #{path}")
Process.sleep(10 * 60_000)
Longx.Jobs.stop_all(thread.kernel_thread_id)
Application.stop(:longx)
Supervisor.stop(model_server)
