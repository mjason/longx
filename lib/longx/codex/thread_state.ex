defmodule Longx.Codex.ThreadState do
  @moduledoc """
  One process per live codex thread. It is the single place events for that
  thread pass through, so it can (1) fold them into a
  `Longx.Codex.ThreadState.View`, (2) stamp each with a strictly increasing
  `seq`, and (3) broadcast `{:codex, seq, method, params}` on
  `"codex:thread:<id>"`.

  A client that must survive a page refresh does, in this order:

      ThreadState.subscribe(thread_id)
      snapshot = ThreadState.snapshot(thread_id)   # %{seq: n, items: …, …}
      # render the snapshot, then apply only events with seq > n

  Server → client requests (approvals…) are registered with
  `put_request/4` and broadcast with a `"requestId"`, and removed again with
  `resolve_request/2`; the snapshot lists the pending ones.
  """

  use GenServer

  alias Longx.Codex.ThreadState.View
  alias Phoenix.PubSub

  @registry Longx.Codex.ThreadRegistry
  @supervisor Longx.Codex.ThreadState.Supervisor
  @pubsub Longx.PubSub

  @type snapshot :: %{
          seq: non_neg_integer,
          thread_id: String.t(),
          thread: map | nil,
          turn: map | nil,
          status: map | nil,
          token_usage: map | nil,
          items: [map],
          pending_requests: [map]
        }

  ## Client

  @spec topic(String.t()) :: String.t()
  def topic(thread_id), do: "codex:thread:" <> thread_id

  @doc "Starts the process for `thread_id` unless it already runs."
  @spec ensure(String.t()) :: {:ok, pid} | {:error, term}
  def ensure(thread_id) do
    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, thread_id}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  @spec whereis(String.t()) :: pid | nil
  def whereis(thread_id), do: GenServer.whereis(via(thread_id))

  @spec stop(String.t()) :: :ok
  def stop(thread_id) do
    case whereis(thread_id) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(@supervisor, pid)
    end
  end

  @spec subscribe(String.t()) :: :ok | {:error, term}
  def subscribe(thread_id), do: PubSub.subscribe(@pubsub, topic(thread_id))

  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(thread_id), do: PubSub.unsubscribe(@pubsub, topic(thread_id))

  @doc "Folds and broadcasts one notification. Fire-and-forget; ordering is the caller's mailbox order."
  @spec ingest(String.t(), String.t(), map) :: :ok
  def ingest(thread_id, method, params),
    do: GenServer.cast(via(thread_id), {:ingest, method, params})

  @spec put_request(String.t(), term, String.t(), map) :: :ok
  def put_request(thread_id, id, method, params),
    do: GenServer.cast(via(thread_id), {:put_request, id, method, params})

  @spec resolve_request(String.t(), term) :: :ok
  def resolve_request(thread_id, id), do: GenServer.cast(via(thread_id), {:resolve_request, id})

  @spec backfill(String.t(), map) :: :ok
  def backfill(thread_id, thread_read_result),
    do: GenServer.call(via(thread_id), {:backfill, thread_read_result})

  @spec snapshot(String.t()) :: snapshot
  def snapshot(thread_id), do: GenServer.call(via(thread_id), :snapshot)

  def start_link(thread_id), do: GenServer.start_link(__MODULE__, thread_id, name: via(thread_id))

  def child_spec(thread_id),
    do: %{
      id: {__MODULE__, thread_id},
      start: {__MODULE__, :start_link, [thread_id]},
      restart: :transient
    }

  defp via(thread_id), do: {:via, Registry, {@registry, thread_id}}

  ## Server

  @impl true
  def init(thread_id), do: {:ok, %{view: View.new(thread_id), seq: 0}}

  @impl true
  def handle_cast({:ingest, method, params}, state) do
    {:noreply, state |> update_view(&View.fold(&1, method, params)) |> broadcast(method, params)}
  end

  def handle_cast({:put_request, id, method, params}, state) do
    {:noreply,
     state
     |> update_view(&View.put_request(&1, id, method, params))
     |> broadcast(method, Map.put(params, "requestId", id))}
  end

  def handle_cast({:resolve_request, id}, state) do
    {:noreply,
     state
     |> update_view(&View.resolve_request(&1, id))
     |> broadcast("serverRequest/resolved", %{"requestId" => id})}
  end

  @impl true
  def handle_call({:backfill, result}, _from, state) do
    {:reply, :ok, update_view(state, &View.backfill(&1, result))}
  end

  def handle_call(:snapshot, _from, %{view: view, seq: seq} = state) do
    {:reply,
     %{
       seq: seq,
       thread_id: view.thread_id,
       thread: view.thread,
       turn: view.turn,
       status: view.status,
       token_usage: view.token_usage,
       items: View.items(view),
       pending_requests: View.pending_requests(view)
     }, state}
  end

  defp update_view(state, fun), do: %{state | view: fun.(state.view)}

  defp broadcast(%{seq: seq, view: view} = state, method, params) do
    seq = seq + 1
    PubSub.broadcast(@pubsub, topic(view.thread_id), {:codex, seq, method, params})
    %{state | seq: seq}
  end
end
