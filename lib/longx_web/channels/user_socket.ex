defmodule LongxWeb.UserSocket do
  @moduledoc "The browser's (and later the phone's) socket: thread streams and project signals."

  use Phoenix.Socket

  channel "thread:*", LongxWeb.ThreadChannel
  channel "project:*", LongxWeb.ProjectChannel
  channel "notify", LongxWeb.NotifyChannel

  @impl true
  def connect(params, socket, connect_info) do
    with {:ok, actor} <- LongxWeb.Actor.from_socket_params(params, connect_info) do
      {:ok, assign(socket, :actor, actor)}
    end
  end

  # single user: no per-user socket id to disconnect by (yet)
  @impl true
  def id(_socket), do: nil
end
