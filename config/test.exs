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
config :longx, Longx.Browser, executable: "/nonexistent/obscura", queue_timeout: 1_000

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

# the agent kernel retries a failed model call at once in tests
config :longx, Longx.Agent.Model, retry_ms: [10, 10]

# no global agent layer in tests (a test that wants one points this at its own directory)
config :longx, Longx.Agent.Loader, global_dir: Path.expand("../data/agent_test_none", __DIR__)
