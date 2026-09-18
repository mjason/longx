defmodule LongxWeb.UserSocketTest do
  @moduledoc """
  The user socket: its websocket carries `connect_info: [:uri]` (what
  `LongxWeb.Origins` reads — the endpoint had it only on the LiveView
  socket, so the browser's address was never remembered) and Longx's own
  serializer (an encode failure is an error frame, not a dead connection).
  """
  use LongxWeb.ChannelCase, async: false

  test "the endpoint hands the user socket the request uri and Longx's serializer" do
    {"/socket", LongxWeb.UserSocket, opts} =
      Enum.find(LongxWeb.Endpoint.__sockets__(), fn {path, _, _} -> path == "/socket" end)

    websocket = Keyword.fetch!(opts, :websocket)
    assert :uri in Keyword.fetch!(websocket, :connect_info)
    assert [{LongxWeb.Socket.Serializer, "~> 2.0"}] = Keyword.fetch!(websocket, :serializer)
  end

  test "connecting remembers where the browser came from", _ do
    LongxWeb.Origins.forget()
    on_exit(fn -> LongxWeb.Origins.forget() end)

    assert {:ok, _socket} =
             connect(LongxWeb.UserSocket, %{},
               connect_info: %{
                 uri: %URI{
                   scheme: "http",
                   host: "192.168.2.70",
                   port: 7788,
                   path: "/socket/websocket"
                 }
               }
             )

    assert LongxWeb.Origins.last() == "http://192.168.2.70:7788"
  end
end
