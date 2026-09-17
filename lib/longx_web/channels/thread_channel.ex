defmodule LongxWeb.ThreadChannel do
  @moduledoc """
  `thread:<kernel_thread_id>` — the live view of one thread, exactly the
  `Longx.Agent.ThreadState` protocol: join answers with the snapshot (its
  `seq` included), then every event arrives as a `"codex"` push
  `%{seq, method, params}` (the event name stayed when the engine changed).
  A client applies only `seq > snapshot.seq`, and after a reconnect simply
  re-joins (or asks for `"snapshot"` again).
  """

  use Phoenix.Channel

  alias Longx.Agent.ThreadState
  alias Longx.Projects

  # joining starts the thread's agent again when it left (Projects.host_thread/1)
  @impl true
  def join("thread:" <> thread_id, _payload, socket) do
    case Projects.host_thread(thread_id) do
      {:ok, current_id} ->
        :ok = ThreadState.subscribe(current_id)
        {:ok, ThreadState.snapshot(current_id), assign(socket, :thread_id, current_id)}

      {:error, reason} ->
        {:error, %{reason: describe(reason)}}
    end
  end

  defp describe(:unknown_thread), do: "unknown thread"
  defp describe(reason), do: "cannot open thread: #{inspect(reason)}"

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
