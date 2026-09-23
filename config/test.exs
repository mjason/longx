import Config

# Fixed test key for Longx.Vault (encrypts provider API keys). Never reuse in prod.
config :longx, Longx.Vault,
  ciphers: [
    default:
      {Cloak.Ciphers.AES.GCM,
       tag: "AES.GCM.V1", key: Base.decode64!("bG9uZ3gtdGVzdC12YXVsdC1rZXktMTIzNDU2Nzg5YWI=")}
  ]

config :ash, policies: [show_policy_breakdowns?: true], disable_async?: true

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :longx, Longx.Repo,
  database: Path.expand("../longx_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :longx, LongxWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "LXuCE06Bz2YjV1d1MK/E81yutDflBOHM2p4riw+Y74JryIi9C7WfGMN6AYaHGByu",
  server: false

# In test we don't send emails
config :longx, Longx.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

config :longx, Longx.Projects.Attachments, dir: Path.expand("../data/attachments_test", __DIR__)

# The headless browser is never the real one in the unit suite: unavailable
# unless a test points `executable:` at test/support/fake_obscura.sh
config :longx, Longx.Browser,
  executable: "/nonexistent/obscura",
  dir: Path.join(System.tmp_dir!(), "longx-obscura-test"),
  # an obscura on the box's PATH must never leak into the suite (tests that
  # want one give `path:` or set this to their own directory)
  queue_timeout: 1_000

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# The SPA shell renders tags from a fixed manifest; no dev server in tests
config :longx, LongxWeb.Vite,
  dev_server: nil,
  manifest: Path.expand("../test/support/vite_manifest.json", __DIR__)

# no background release checks in the suite; tests configure the rest
config :longx, Longx.Upgrade, tick: nil
# the memory watchdog's clock is off in the suite: tests sweep by hand
config :longx, Longx.System.Pressure, tick: nil

# no job runs by itself in the suite (Oban.Testing drives the workers)
config :longx, Oban, testing: :manual

# the agent kernel retries a failed model call at once in tests
config :longx, Longx.Agent.Model, retry_ms: [10, 10]

# no global agent layer in tests (a test that wants one points this at its own directory)
config :longx, Longx.Agent.Knowledge,
  global_dir: Path.expand("../data/agent_test_none/knowledge", __DIR__)

# no report leaves the suite unless a test points the DSN at its Bypass
config :sentry, dsn: nil, environment_name: :test

# the page rereads a changed agent description (the channel polls its files
# only when the watcher is unavailable); the watcher leaves soon after the last page
config :longx, LongxWeb.ProjectChannel, definition_poll_ms: 100
config :longx, Longx.Projects.Watcher, grace_ms: 100

# the model requests' pool replaces a connection idle this long (30 s in prod)
config :longx, Longx.AI.Finch, conn_max_idle_time: 200
