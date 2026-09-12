defmodule LongxWeb.Actor do
  @moduledoc """
  Who is acting. Longx is single-user and has no authentication yet; this
  is the one place that will change when AshAuthentication arrives (a
  `current_user` from the session for RPC, a token for sockets and mobile
  clients). Until then everything acts as `nil`.
  """

  @spec from_conn(Plug.Conn.t()) :: nil
  def from_conn(_conn), do: nil

  @spec from_socket_params(map, map) :: {:ok, nil | term} | :error
  def from_socket_params(_params, _connect_info), do: {:ok, nil}
end
