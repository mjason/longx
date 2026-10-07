# Opt-in isolated live Phoenix server; not loaded by ExUnit or a release.
# The coordinating session starts it, optionally under a delegated test unit:
# MIX_ENV=test LONGX_CGROUP_E2E_DIR=<fresh scoped dir>
# LONGX_CGROUP_E2E_PORT=17888 LONGX_CGROUP_E2E_EXPECT=eligible
# mix run --no-start test/support/cgroup_e2e_server.exs
unless Mix.env() == :test, do: raise("cgroup E2E requires MIX_ENV=test")

root = System.fetch_env!("LONGX_CGROUP_E2E_DIR") |> Path.expand()
artifacts = Path.expand(".longx/local/artifacts")
scoped = Path.relative_to(root, artifacts) |> Path.split()

safe_root? =
  case scoped do
    ["cgroup-live-e2e", run] ->
      run not in ["", ".", ".."]

    ["cgroup-live-e2e", run, branch]
    when branch in ["delegated", "nondelegated", "plain", "unavailable"] ->
      Regex.match?(~r/\Arun-[A-Za-z0-9]+\z/, run)

    [run, branch] when branch in ["A", "B", "a", "b"] ->
      Regex.match?(~r/\Acgroup-live-e2e-[A-Za-z0-9]+\z/, run)

    _ ->
      false
  end

unless safe_root?, do: raise("use a fresh cgroup-live-e2e run directory under #{artifacts}")

database = Path.join(root, "e2e.db")

if File.exists?(database),
  do: raise("refusing a pre-existing E2E database; use a fresh run directory")

File.mkdir_p!(root)
evidence_dir = Path.join(root, "evidence")
project_dir = Path.join(root, "project")
File.mkdir_p!(evidence_dir)
File.mkdir_p!(project_dir)

port = System.fetch_env!("LONGX_CGROUP_E2E_PORT") |> String.to_integer()
unless port in 1024..65_535, do: raise("invalid loopback test port")
expected = System.fetch_env!("LONGX_CGROUP_E2E_EXPECT")
unless expected in ["eligible", "unavailable"], do: raise("invalid expected capability")

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
      {Longx.Tls,
       [dir: Path.join(root, "tls"), tool_dir: Path.join(root, "cert-tool"), public_dns: []]},
      {Longx.Browser, [dir: Path.join(root, "browser"), executable: "/nonexistent/e2e-browser"]},
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

# Migrate the isolated database explicitly before the app starts accepting HTTP.
# Keep the ordinary test boot's migration skip after this one-connection migration.
System.delete_env("RELEASE_NAME")
{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Application.ensure_all_started(:ecto_sqlite3)
:ok = Longx.Migrator.migrate(database: database)
{:ok, _} = Application.ensure_all_started(:longx)

report = Longx.System.CommandGuard.report(Longx.Agent.Definition.Settings.global())
unless report.capability == expected, do: raise("capability mismatch: #{inspect(report)}")

identity_path = Path.join(root, "runner.json")

{:ok, model_server} =
  Bandit.start_link(
    plug: {Longx.Test.CgroupE2EModel, evidence_dir: evidence_dir, identity_path: identity_path},
    ip: {127, 0, 0, 1},
    port: 0
  )

{:ok, {_ip, model_port}} = ThousandIsland.listener_info(model_server)

provider =
  Longx.AI.create_provider!(%{
    name: "Local cgroup E2E only",
    slug: "cgroup-e2e-local",
    base_url: "http://127.0.0.1:#{model_port}/v1",
    api_key: "local-test-only-not-a-provider-key"
  })

model =
  Longx.AI.create_model!(%{
    name: "Local cgroup E2E only",
    slug: "cgroup-e2e",
    upstream_id: "cgroup-e2e",
    provider_id: provider.id
  })

{:ok, _} = Longx.AI.set_default_model(model.slug)
project = Longx.Projects.create_project!(%{name: "Isolated cgroup E2E", root_path: project_dir})

identity = %{
  test_only: true,
  run_id: Ecto.UUID.generate(),
  root: root,
  evidence_dir: evidence_dir,
  url: "http://127.0.0.1:#{port}",
  model_url: "http://127.0.0.1:#{model_port}",
  model: model.slug,
  expected_capability: expected,
  initial_report: report,
  server_membership: File.read!("/proc/self/cgroup") |> String.trim(),
  project: %{id: project.id, slug: project.slug, root_path: project.root_path}
}

File.write!(identity_path, Jason.encode!(identity, pretty: true))
IO.puts("CGROUP_E2E_READY #{identity_path}")
# A forgotten test server cannot live indefinitely; the coordinator normally stops it first.
Process.sleep(10 * 60_000)
:ok = Application.stop(:longx)
:ok = Supervisor.stop(model_server)
raise "isolated cgroup E2E server reached its ten-minute safety deadline"
