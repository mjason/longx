defmodule LongxWeb.Router do
  use LongxWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {LongxWeb.Layouts, :root}
    # a paired phone's bearer waives CSRF (LongxWeb.Plugs.Bearer, before the check)
    plug LongxWeb.Plugs.Bearer
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  # The SPA shell decides for itself whether a request is a page (no
  # `:accepts`: an API client hitting an unknown path gets a 404, not a 406).
  pipeline :spa do
    plug :fetch_session
    plug :put_root_layout, html: {LongxWeb.Layouts, :spa_root}
    plug :protect_from_forgery
    # Phoenix's default permissions-policy names ad-tech features Chrome does
    # not recognise (console noise on every page); ours says what we mean.
    plug :put_secure_browser_headers, %{
      "permissions-policy" => "camera=(), microphone=(), geolocation=(), payment=()"
    }
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # OpenAI-compatible surface the bundled codex-app-server talks to. No
  # `:accepts` here: codex sends `Accept: text/event-stream` and the gateway
  # decides the response format itself.
  pipeline :ai_gateway do
    plug LongxWeb.Plugs.GatewayAuth
  end

  scope "/", LongxWeb do
    pipe_through :browser

    post "/rpc/run", AshTypescriptRpcController, :run
    post "/rpc/validate", AshTypescriptRpcController, :validate
    # the composer's file attachments (multipart; CSRF like the RPC calls)
    post "/attachments/:project_id", AttachmentController, :create
  end

  # the phone's pairing call: no session, no CSRF — a code is all it has
  scope "/", LongxWeb do
    pipe_through :api

    post "/pair", PairController, :create
  end

  scope "/ai/v1", LongxWeb.AI do
    pipe_through :ai_gateway

    post "/responses", ResponsesController, :create
    # codex standalone web search (`web.run` tool) — see Longx.AI.Search
    post "/alpha/search", SearchController, :create
  end

  # codex's exec-server: its commands and file operations come in here (the
  # `url` in each home's environments.toml) — a bare route, the token is in
  # the URL and the controller upgrades to a WebSocket.
  scope "/exec", LongxWeb do
    get "/:project_id", ExecController, :connect
  end

  # Other scopes may use custom stacks.
  # scope "/api", LongxWeb do
  #   pipe_through :api
  # end

  # The React SPA: every remaining HTML path gets the shell (see
  # LongxWeb.PageController). Must stay last — after /ai, /rpc and /dev.
  scope "/", LongxWeb do
    pipe_through :spa

    get "/", PageController, :spa
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:longx, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: LongxWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  scope "/", LongxWeb do
    pipe_through :spa

    get "/*path", PageController, :spa
  end
end
