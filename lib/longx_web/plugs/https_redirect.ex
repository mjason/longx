defmodule LongxWeb.Plugs.HttpsRedirect do
  @moduledoc """
  While Longx serves HTTPS itself (`Longx.Tls`) and the settings say to, a
  page a browser asks for over plain http is sent to the https address with
  its path and query (307: turning HTTPS off later sends nobody astray).
  Only page navigations move — the health check, the API, webhooks,
  callbacks, downloads, the sockets (the Chrome extension, an Android shell
  pointed at the http address) and the GraphQL calls keep working on http.
  Nor does the HTTPS settings page itself: when the name does not resolve
  from the browser's machine (the A record missing, another network), every
  other page would be sent somewhere unreachable, and this one is the way to
  fix or turn it off.
  """

  @behaviour Plug

  import Plug.Conn

  @stay ~w(/health /api/ /hooks/ /callback/ /files/ /extension/ /socket /chrome/ /gql /attachments/ /assets/ /dev/ /settings/https)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{scheme: :http, method: method} = conn, _opts)
      when method in ["GET", "HEAD"] do
    with url when is_binary(url) <- Longx.Tls.redirect_url(),
         true <- page?(conn),
         false <- stays?(conn.request_path) do
      query = if conn.query_string == "", do: "", else: "?" <> conn.query_string

      conn
      |> put_resp_header("location", url <> conn.request_path <> query)
      |> send_resp(307, "")
      |> halt()
    else
      _ -> conn
    end
  end

  def call(conn, _opts), do: conn

  defp page?(conn),
    do: conn |> get_req_header("accept") |> Enum.any?(&String.contains?(&1, "text/html"))

  defp stays?(path), do: Enum.any?(@stay, &String.starts_with?(path, &1))
end
