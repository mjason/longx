defmodule LongxWeb.Plugs.Bearer do
  @moduledoc """
  A paired phone's token on `Authorization: Bearer …` (`Longx.System.Device`).
  A valid one puts the device on the conn and waives CSRF — a bearer
  request cannot be forged by a page; an invalid one is refused. No header
  is the browser, which goes on to the session and its CSRF token.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        case Longx.System.authenticate_device(token) do
          {:ok, device} ->
            conn
            |> assign(:device, device)
            |> put_private(:plug_skip_csrf_protection, true)

          :error ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(401, Jason.encode!(%{error: "invalid device token"}))
            |> halt()
        end

      _ ->
        conn
    end
  end
end
