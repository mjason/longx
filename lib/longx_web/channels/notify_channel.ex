defmodule LongxWeb.NotifyChannel do
  @moduledoc """
  `notify` — `Longx.Notify`'s feed on the wire. The join reply carries what
  runs now (`running`: `Longx.Projects.running_threads/0`, `waiting` marking
  the ones that need the person), so a client that was away sees the
  current state; then every event is one `"event"` push.
  """

  use Phoenix.Channel

  alias Longx.Notify
  alias Longx.Projects
  alias Phoenix.PubSub

  @impl true
  def join("notify", _payload, socket) do
    :ok = PubSub.subscribe(Longx.PubSub, Notify.topic())
    {:ok, %{running: Projects.running_threads()}, socket}
  end

  @impl true
  def handle_info({:notify, event}, socket) do
    push(socket, "event", event)
    {:noreply, socket}
  end

  def handle_info(_other, socket), do: {:noreply, socket}
end
