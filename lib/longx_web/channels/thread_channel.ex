defmodule LongxWeb.ThreadChannel do
  @moduledoc """
  `thread:<codex_thread_id>` — the live view of one thread, exactly the
  `Longx.Codex.ThreadState` protocol: join answers with the snapshot (its
  `seq` included), then every event arrives as a `"codex"` push
  `%{seq, method, params}`. A client applies only `seq > snapshot.seq`, and
  after a reconnect simply re-joins (or asks for `"snapshot"` again).
  """

  use Phoenix.Channel

  alias Longx.Codex.{Pool, ThreadState}

  @impl true
  def join("thread:" <> thread_id, _payload, socket) do
    case Pool.connection_for_thread(thread_id) do
      {:ok, _conn} ->
        :ok = ThreadState.subscribe(thread_id)
        {:ok, ThreadState.snapshot(thread_id), assign(socket, :thread_id, thread_id)}

      {:error, :no_connection} ->
        {:error, %{reason: "unknown thread"}}
    end
  end

  @impl true
  def handle_in("snapshot", _payload, socket) do
    {:reply, {:ok, ThreadState.snapshot(socket.assigns.thread_id)}, socket}
  end

  @impl true
  def handle_info({:codex, seq, method, params}, socket) do
    push(socket, "codex", %{seq: seq, method: method, params: params})
    {:noreply, socket}
  end

  def handle_info(_other, socket), do: {:noreply, socket}
end
