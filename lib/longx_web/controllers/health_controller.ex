defmodule LongxWeb.HealthController do
  @moduledoc """
  `GET /health` — what a container's `HEALTHCHECK` and a reverse proxy's
  probe ask: `200 ok` once the endpoint answers, the version in a header.
  No session, no CSRF, no JSON: a plain text line.
  """
  use LongxWeb, :controller

  def show(conn, _params) do
    conn
    |> put_resp_header("x-longx-version", Longx.Upgrade.current_version())
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "ok")
  end
end
