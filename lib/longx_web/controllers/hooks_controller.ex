defmodule LongxWeb.HooksController do
  @moduledoc """
  `POST /hooks/:token` — a webhook watch's trigger (`Longx.Watches`): the
  watch whose token this is gets one run queued with the request body as
  its `ctx.payload` (JSON decoded, anything else a string, 8 KB kept). A
  run already queued or executing swallows a second call (the runner is
  unique per watch). No session, no CSRF: the token is the secret.
  """
  use LongxWeb, :controller

  alias Longx.Watches

  @payload_bytes 8_192

  def create(conn, %{"token" => token}) do
    case Watches.get_by_token(token) do
      {:ok, %Watches.Watch{enabled: false}} ->
        send_resp(conn, 409, "this watch is off")

      {:ok, %Watches.Watch{id: id}} ->
        {:ok, _} = Oban.insert(Watches.Runner.new(%{"id" => id, "payload" => payload(conn)}))
        send_resp(conn, 202, "queued")

      {:error, _} ->
        send_resp(conn, 404, "no such hook")
    end
  end

  # the parsed JSON body when there was one (the endpoint's parsers read
  # JSON), else the raw text
  defp payload(%Plug.Conn{body_params: %{} = params})
       when map_size(params) > 0 and not is_struct(params), do: params

  # a text body the parsers did not read (text/plain is not theirs)
  defp payload(conn) do
    case read(conn) do
      "" ->
        nil

      text ->
        text |> binary_part(0, min(byte_size(text), @payload_bytes)) |> Longx.Agent.Text.utf8()
    end
  end

  defp read(conn) do
    case Plug.Conn.read_body(conn, length: @payload_bytes) do
      {:ok, body, _} -> body
      {:more, body, _} -> body
      _ -> ""
    end
  end
end
