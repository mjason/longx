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
  alias Longx.Projects

  # A thread some codex hosts (ad-hoc connections included) joins directly;
  # a project thread nobody hosts is resumed on its project's codex first
  # (an empty one is started again — the snapshot then carries the new id,
  # which is what the client follows from there); a thread codex can no
  # longer know still shows its last view, read-only.
  @impl true
  def join("thread:" <> thread_id, _payload, socket) do
    case host(thread_id) do
      {:ok, current_id} ->
        :ok = ThreadState.subscribe(current_id)
        {:ok, ThreadState.snapshot(current_id), assign(socket, :thread_id, current_id)}

      {:error, reason} ->
        {:error, %{reason: describe(reason)}}
    end
  end

  defp host(thread_id) do
    case Pool.connection_for_thread(thread_id) do
      {:ok, _conn} -> {:ok, thread_id}
      {:error, :no_connection} -> Projects.host_thread(thread_id)
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
