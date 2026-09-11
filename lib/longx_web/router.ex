defmodule LongxWeb.Router do
  use LongxWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {LongxWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
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

    get "/", PageController, :home
    post "/rpc/run", AshTypescriptRpcController, :run
    post "/rpc/validate", AshTypescriptRpcController, :validate
    get "/ash-typescript", PageController, :index
  end

  scope "/ai/v1", LongxWeb.AI do
    pipe_through :ai_gateway

    post "/responses", ResponsesController, :create
  end

  # Other scopes may use custom stacks.
  # scope "/api", LongxWeb do
  #   pipe_through :api
  # end

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
end
