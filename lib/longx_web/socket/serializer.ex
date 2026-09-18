defmodule LongxWeb.Socket.Serializer do
  @moduledoc """
  Phoenix's V2 JSON serializer, except that a frame it cannot encode
  becomes an error frame instead of a raise: a raise here runs in the
  socket transport and closes the connection for every channel on it.
  `LongxWeb.Wire.clean/1` makes this the last resort, not the first.
  """

  @behaviour Phoenix.Socket.Serializer

  alias Phoenix.Socket.{Broadcast, Message, Reply}
  alias Phoenix.Socket.V2.JSONSerializer, as: V2

  require Logger

  @impl true
  def decode!(raw, opts), do: V2.decode!(raw, opts)

  @impl true
  def fastlane!(%Broadcast{} = msg) do
    V2.fastlane!(msg)
  rescue
    e ->
      warn(msg.topic, msg.event, e)
      V2.fastlane!(%Broadcast{msg | event: "longx/error", payload: error_payload(msg.event, e)})
  end

  @impl true
  def encode!(%Reply{} = reply) do
    V2.encode!(reply)
  rescue
    e ->
      warn(reply.topic, "phx_reply", e)
      V2.encode!(%Reply{reply | status: :error, payload: error_payload("phx_reply", e)})
  end

  def encode!(%Message{} = msg) do
    V2.encode!(msg)
  rescue
    e ->
      warn(msg.topic, msg.event, e)
      V2.encode!(%Message{msg | event: "longx/error", payload: error_payload(msg.event, e)})
  end

  defp error_payload(event, e),
    do: %{"reason" => "not encodable: " <> Exception.message(e), "event" => event}

  defp warn(topic, event, e) do
    Logger.error("socket: could not encode #{event} on #{topic}: #{Exception.message(e)}")

    Longx.System.Faults.record(
      :socket_encode,
      topic,
      "could not encode #{event}: #{Exception.message(e)}"
    )
  end
end
