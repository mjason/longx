defmodule LongxWeb.Endpoint do
  # exceptions in requests reported when a DSN is set (Longx.Sentry)
  use Sentry.PlugCapture
  use Phoenix.Endpoint, otp_app: :longx

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_longx_key",
    signing_salt: "l9Hs0F/p",
    same_site: "Lax"
  ]

  # the request uri for LongxWeb.Origins (the address the browser reached
  # Longx by), and the serializer that answers an encode failure with an
  # error frame, never a crash of the transport (LongxWeb.Socket.Serializer);
  # frames compressed (permessage-deflate) — a long thread's snapshot is
  # megabytes of JSON, and on a weak network every one of them is seconds
  socket "/socket", LongxWeb.UserSocket,
    websocket: [
      connect_info: [:uri],
      serializer: [{LongxWeb.Socket.Serializer, "~> 2.0"}],
      compress: true
    ],
    longpoll: false

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [:uri, session: @session_options]],
    longpoll: [connect_info: [:uri, session: @session_options]]

  # Vite's output (assets/js/build/plugins.ts): every file named by its
  # hash, so a browser keeps it for good — no revalidation round trip per
  # file on each load — and sent as the .br / .gz the build writes beside
  # it. The 3.7 MB entry of 0.2.64 went out raw (`gzip:` serves only a .gz
  # that exists, and nothing wrote one): 21 s at 1.5 Mbps.
  plug Plug.Static,
    at: "/assets",
    from: {:longx, "priv/static/assets"},
    gzip: not code_reloading?,
    brotli: not code_reloading?,
    cache_control_for_etags: "public, max-age=31536000, immutable"

  # the rest of priv/static (icons, the PWA manifest): compressed when a
  # compressed copy is there, revalidated as usual
  plug Plug.Static,
    at: "/",
    from: :longx,
    gzip: not code_reloading?,
    brotli: not code_reloading?,
    only: LongxWeb.static_paths(),
    raise_on_missing_only: code_reloading?

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
    plug AshPhoenix.Plug.CheckCodegenStatus
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :longx
  end

  plug Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    # multipart: the composer's attachments (a zip, a dataset) — 512 MB
    parsers: [:urlencoded, {:multipart, length: 512_000_000}, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  # the request on a reported exception (method, path, headers without cookies)
  plug Sentry.PlugContext

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug LongxWeb.Router
end
