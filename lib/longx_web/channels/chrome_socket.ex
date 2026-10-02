defmodule LongxWeb.ChromeSocket do
  @moduledoc """
  The Longx Chrome extension's socket (`/chrome/socket`): an extension
  connects out to Longx with its `install_id`, its `token` once paired, and
  what it knows about its device; the pairing itself happens at the join
  of `chrome:bridge` (`LongxWeb.ChromeChannel`). The endpoint mounts it
  with `check_origin: false` — the Origin is `chrome-extension://…`, no
  host of ours — and the token is the trust.
  """

  use Phoenix.Socket

  channel "chrome:bridge", LongxWeb.ChromeChannel

  @impl true
  def connect(%{"install_id" => install_id} = params, socket, connect_info)
      when is_binary(install_id) and install_id != "" do
    device = if is_map(params["device"]), do: params["device"], else: %{}
    device = Map.delete(device, "peer_ip")

    device =
      case connect_info do
        %{peer_data: %{address: address}} when is_tuple(address) ->
          Map.put(device, "peer_ip", address |> :inet.ntoa() |> to_string())

        _ ->
          device
      end

    {:ok, assign(socket, install_id: install_id, token: params["token"], device: device)}
  end

  def connect(_params, _socket, _connect_info), do: :error

  # one socket per extension install: a revocation disconnects it by this id
  @impl true
  def id(socket), do: "chrome_socket:" <> socket.assigns.install_id
end
