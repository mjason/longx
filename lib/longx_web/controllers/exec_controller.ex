defmodule LongxWeb.ExecController do
  @moduledoc """
  `GET /exec/:project_id?token=…` — upgrades codex's connection to the
  exec-server (`LongxWeb.ExecSocket`). The token is the per-boot gateway
  token (`Longx.AI.Gateway.Token`), carried in the URL because codex sends
  no headers on a plain `ws://` environment; the URL only ever lives in the
  project's `environments.toml`, inside the data directory.
  """

  use LongxWeb, :controller

  alias Longx.AI.Gateway.Token

  # codex sends no keepalive on a local environment; the socket pings itself
  @idle_timeout 7 * 24 * 60 * 60 * 1000

  def connect(conn, %{"project_id" => project_id} = params) do
    if Token.valid?(params["token"]) do
      WebSockAdapter.upgrade(conn, LongxWeb.ExecSocket, %{project_id: project_id},
        timeout: @idle_timeout
      )
    else
      conn |> send_resp(401, "missing or invalid gateway token") |> halt()
    end
  end
end
