defmodule LongxWeb.Plugs.GatewayAuth do
  @moduledoc "Requires `Authorization: Bearer <Longx.AI.Gateway.Token>` on the AI gateway routes."

  import Plug.Conn

  alias Longx.AI.Gateway

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         true <- Gateway.Token.valid?(token) do
      conn
    else
      _ ->
        conn
        |> Gateway.error(401, "missing or invalid gateway token")
        |> halt()
    end
  end
end
