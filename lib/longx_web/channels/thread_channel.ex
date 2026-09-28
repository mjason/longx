defmodule LongxWeb.ThreadChannel do
  @moduledoc """
  `thread:<kernel_thread_id>` — the live view of one thread, exactly the
  `Longx.Agent.ThreadState` protocol: join answers with the snapshot (its
  `seq` included), then every event arrives as an `"event"` push
  `%{seq, method, params}` (the event name stayed when the engine changed).
  A client applies only `seq > snapshot.seq`, and after a reconnect simply
  re-joins (or asks for `"snapshot"` again).

  The snapshot is a window: the join's `limit` (an item count, or `"all"`;
  `ThreadState.default_window/0` when absent) is how many items of the tail
  come with it, `earlier` says what is above, and `"earlier"` `%{before,
  limit}` pages up from an item the client has.
  """

  use Phoenix.Channel

  alias Longx.Agent.ThreadState
  alias Longx.Projects
  alias LongxWeb.Wire

  # joining starts the thread's agent again when it left (Projects.host_thread/1)
  @impl true
  def join("thread:" <> thread_id, payload, socket) do
    case Projects.host_thread(thread_id) do
      {:ok, current_id} ->
        :ok = ThreadState.subscribe(current_id)

        {:ok, Wire.clean(ThreadState.snapshot(current_id, limit: limit(payload))),
         assign(socket, :thread_id, current_id)}

      {:error, reason} ->
        {:error, %{reason: describe(reason)}}
    end
  end

  defp describe(:unknown_thread), do: "unknown thread"
  defp describe(reason), do: "cannot open thread: #{inspect(reason)}"

  @impl true
  def handle_in("snapshot", payload, socket) do
    id = socket.assigns.thread_id
    snapshot = ThreadState.snapshot(id, limit: limit(payload))
    {:reply, {:ok, Wire.clean(snapshot, "thread:" <> id)}, socket}
  end

  def handle_in("earlier", %{"before" => before} = payload, socket) when is_binary(before) do
    id = socket.assigns.thread_id

    case ThreadState.earlier(id, before, limit(payload)) do
      {:ok, page} -> {:reply, {:ok, Wire.clean(page, "thread:" <> id)}, socket}
      {:error, :unknown_item} -> {:reply, {:error, %{reason: "unknown item"}}, socket}
    end
  end

  def handle_in("earlier", _payload, socket),
    do: {:reply, {:error, %{reason: "before: an item id is required"}}, socket}

  defp limit(%{"limit" => "all"}), do: :all
  defp limit(%{"limit" => n}) when is_integer(n) and n > 0, do: n
  defp limit(_payload), do: ThreadState.default_window()

  @impl true
  def handle_info({:thread, seq, method, params}, socket) do
    push(socket, "event", %{
      seq: seq,
      method: method,
      params: Wire.clean(params, "thread:" <> socket.assigns.thread_id)
    })

    {:noreply, socket}
  end

  def handle_info(_other, socket), do: {:noreply, socket}
end
