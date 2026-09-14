import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/longx start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :longx, LongxWeb.Endpoint, server: true
end

# Where the self-upgrade looks for releases (Longx.Upgrade): a fork or a
# mirror sets its own repository / API host; the systemd unit's name is
# LONGX_SERVICE (default longx), read by Longx.Upgrade itself.
if repo = System.get_env("LONGX_UPDATE_REPO") do
  config :longx, Longx.Upgrade, repo: repo
end

if api = System.get_env("LONGX_UPDATE_API") do
  config :longx, Longx.Upgrade, api_url: api
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :longx, LongxWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/longx_web/router\.ex$"E,
        ~r"lib/longx_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  # A self-hosted release needs one thing: where to keep its state. The
  # database, codex's home and the two secrets live under LONGX_DATA_DIR;
  # the secrets are generated on first boot and kept in files there, unless
  # given as environment variables.
  data_dir =
    System.get_env("LONGX_DATA_DIR") ||
      raise """
      environment variable LONGX_DATA_DIR is missing.
      It holds the database, the bundled codex-app-server's state and the
      generated secrets, e.g. /var/lib/longx
      """

  File.mkdir_p!(data_dir)

  secret_file = fn name, generate ->
    path = Path.join(data_dir, name)

    case File.read(path) do
      {:ok, value} ->
        String.trim(value)

      {:error, :enoent} ->
        value = generate.()
        File.write!(path, value <> "\n")
        File.chmod!(path, 0o600)
        value
    end
  end

  config :longx, Longx.Repo,
    database: System.get_env("DATABASE_PATH") || Path.join(data_dir, "longx.db"),
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

  # signs and encrypts cookies
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      secret_file.("secret_key_base", fn -> :crypto.strong_rand_bytes(64) |> Base.encode64() end)

  # encrypts provider API keys at rest — lose it and the keys are unreadable
  cloak_key =
    System.get_env("LONGX_CLOAK_KEY") ||
      secret_file.("cloak_key", fn -> :crypto.strong_rand_bytes(32) |> Base.encode64() end)

  config :longx, Longx.Vault,
    ciphers: [default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: Base.decode64!(cloak_key)}]

  config :longx, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :longx, Longx.Codex.Home, dir: Path.join(data_dir, "codex_home")
  config :longx, Longx.Memory, dir: Path.join(data_dir, "memory")

  # PORT only applies to prod; dev (7788) and test (4002) are fixed in their config files.
  port = String.to_integer(System.get_env("PORT") || "7788")
  host = System.get_env("PHX_HOST") || "localhost"

  # the release serves on its own, plain http on every interface (put a
  # reverse proxy in front for TLS); PHX_HOST is the name links are built with
  config :longx, LongxWeb.Endpoint,
    server: true,
    url: [host: host, port: port, scheme: "http"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :longx, LongxWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :longx, LongxWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :longx, Longx.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
