defmodule LongxWeb.Actor do
  @moduledoc """
  Who is acting. Longx is single-user and has no authentication yet; this
  is the one place that will change when AshAuthentication arrives (a
  `current_user` from the session for RPC, a token for sockets and mobile
  clients). Until then everything acts as `nil`.
  """

  @spec from_conn(Plug.Conn.t()) :: nil
  def from_conn(_conn), do: nil

  # a paired phone joins the socket with its device token (`token` param);
  # a wrong one is refused, none is the browser
  @spec from_socket_params(map, map) :: {:ok, nil | term} | :error
  def from_socket_params(%{"token" => token}, _connect_info) do
    case Longx.System.authenticate_device(token) do
      {:ok, _device} -> {:ok, nil}
      :error -> :error
    end
  end

  def from_socket_params(_params, _connect_info), do: {:ok, nil}
end
