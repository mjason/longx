# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :ash_typescript,
  manifest: Longx.AshTypescriptManifest,
  output_file: "assets/js/ash_rpc.ts",
  run_endpoint: "/rpc/run",
  validate_endpoint: "/rpc/validate",
  input_field_formatter: :camel_case,
  output_field_formatter: :camel_case,
  require_tenant_parameters: false,
  generate_zod_schemas: false,
  generate_phx_channel_rpc_actions: false,
  # CSRF (and later auth) headers on every call, see assets/js/core/rpcHooks.ts
  rpc_action_before_request_hook: "RpcHooks.beforeRequest",
  rpc_validation_before_request_hook: "RpcHooks.beforeValidationRequest",
  rpc_action_hook_context_type: "RpcHooks.ActionHookContext",
  rpc_validation_hook_context_type: "RpcHooks.ValidationHookContext",
  import_into_generated: [%{import_name: "RpcHooks", file: "assets/js/core/rpcHooks"}],
  generate_validation_functions: true,
  zod_import_path: "zod",
  zod_schema_suffix: "ZodSchema",
  generate_valibot_schemas: false,
  valibot_import_path: "valibot",
  valibot_schema_suffix: "ValibotSchema",
  phoenix_import_path: "phoenix"

config :longx, Longx.Repo, timeout: 15_000, busy_timeout: 16_000

# These enable behaviors that will become the default in the next major
# version of Ash. Setting them now opts your application into the new
# behavior and ensures a seamless upgrade. See the backwards compatibility
# guide for an explanation of each setting:
# https://hexdocs.pm/ash/backwards-compatibility-config.html
config :ash,
  allow_forbidden_field_for_relationships_by_default: true,
  include_embedded_source_by_default?: false,
  show_keysets_for_all_actions?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false],
  keep_read_action_loads_when_loading?: false,
  default_actions_require_atomic?: true,
  read_action_after_action_hooks_in_order?: true,
  bulk_actions_default_to_errors?: true,
  transaction_rollback_on_error?: true,
  redact_sensitive_values_in_errors?: true,
  default_string_length_count: :codepoints,
  many_to_many_destroy_destination_on_match?: true

config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [
        :resource,
        :code_interface,
        :actions,
        :policies,
        :pub_sub,
        :preparations,
        :changes,
        :validations,
        :multitenancy,
        :attributes,
        :relationships,
        :calculations,
        :aggregates,
        :identities
      ]
    ],
    "Ash.Domain": [section_order: [:resources, :policies, :authorization, :domain, :execution]]
  ]

config :longx,
  ecto_repos: [Longx.Repo],
  generators: [timestamp_type: :utc_datetime],
  ash_domains: [
    Longx.AI,
    Longx.Projects,
    Longx.System,
    Longx.Watches,
    Longx.Credentials,
    Longx.Agent.Transcript
  ]

# Configure the endpoint
config :longx, LongxWeb.Endpoint,
  url: [host: "localhost"],
  # a self-hosted instance is opened by whatever address the person typed
  # (LAN IP, hostname, Tailscale name): the socket's origin must match the
  # request's own host, not a configured one (PHX_HOST is for links only)
  check_origin: :conn,
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: LongxWeb.ErrorHTML, json: LongxWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Longx.PubSub,
  live_view: [signing_salt: "xM3QOsH2"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :longx, Longx.Mailer, adapter: Swoosh.Adapters.Local

# Assets are built by Vite (assets/vite.config.ts); LongxWeb.Vite renders the
# tags — the dev server's in dev, the manifest's in prod.
config :longx, LongxWeb.Vite,
  manifest: {:priv, "static/assets/.vite/manifest.json"},
  entries: ["js/index.tsx"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
# Error reporting (Longx.Sentry): the SDK starts with no DSN — silent —
# and the one saved in the settings is applied at runtime. The release is
# Longx's version; the source code is not shipped, so no context from it.
config :sentry,
  dsn: nil,
  environment_name: config_env(),
  release: Mix.Project.config()[:version],
  enable_source_code_context: false,
  # a client's protocol trouble at the web server is not reported (Longx.Sentry.before_send/1)
  before_send: {Longx.Sentry, :before_send},
  send_result: :none

import_config "#{config_env()}.exs"

# Self-upgrade from GitHub releases (Longx.Upgrade): where to look, how often
config :longx, Longx.Upgrade, repo: "mjason/longx", tick: :timer.hours(6)

# Background jobs on the SQLite database (Oban's Lite engine): the OAuth2
# token refresh (Longx.Credentials.RefreshWorker) every five minutes
config :longx, Oban,
  engine: Oban.Engines.Lite,
  # the Postgres notifier is the default and needs postgrex; one BEAM, so PG
  notifier: Oban.Notifiers.PG,
  repo: Longx.Repo,
  queues: [credentials: 2, watches: 4],
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"*/5 * * * *", Longx.Credentials.RefreshWorker},
       # the watches' clock: files reconciled, due ones queued (Longx.Watches)
       {"* * * * *", Longx.Watches.Tick}
     ]},
    {Oban.Plugins.Pruner, max_age: 7 * 24 * 60 * 60}
  ]
