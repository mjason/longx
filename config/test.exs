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

config :longx, Longx.Codex.Home, dir: Path.expand("../data/codex_home_test", __DIR__)

# Tests start their own Longx.Codex.Connection against a fake app-server;
# the per-project pool launches the same fake instead of the real binary.
config :longx, Longx.Codex.Pool,
  command: ["elixir", Path.expand("../test/support/fake_app_server.exs", __DIR__)],
  # the fake remembers its threads in the project's home, like codex does
  connection: [env: [{"FAKE_PERSIST", "1"}]]

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
