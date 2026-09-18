defmodule Longx.Agent.ThreadState do
  @moduledoc """
  The single writer for one thread's materialised state (the view the kernel's
  events build, in codex's vocabulary).

  Every event for the thread passes through this process so it can (1) fold
  it into the ETS-backed `Longx.Agent.ThreadState.Store`, (2) stamp it with a
  strictly increasing `seq`, and (3) broadcast `{:thread, seq, method, params}`
  on `"thread:<id>"`. Reads (`snapshot/1`) go straight to ETS and work
  whether or not this process is alive; the sequence continues where it left
  off when the process is restarted.

  A client that must survive a page refresh does, in this order:

      ThreadState.subscribe(thread_id)
      snapshot = ThreadState.snapshot(thread_id)   # %{seq: n, items: …, …}
      # render the snapshot, then apply only events with seq > n

  Server → client requests (approvals…) are registered with
  `put_request/4` and broadcast with a `"requestId"`, and removed again with
  `resolve_request/2`; the snapshot lists the pending ones.
  """

  use GenServer

  alias Longx.Agent.ThreadState.Store

  require Logger
  alias Phoenix.PubSub

  @registry Longx.Agent.ThreadRegistry
  @supervisor Longx.Agent.ThreadState.Supervisor
  @pubsub Longx.PubSub

  @type snapshot :: %{
          seq: non_neg_integer,
          thread_id: String.t(),
          thread: map | nil,
          turn: map | nil,
          turns: %{optional(String.t()) => map},
          status: map | nil,
          token_usage: map | nil,
          goal: map | nil,
          items: [map],
          pending_requests: [map]
        }

  ## Client

  @spec topic(String.t()) :: String.t()
  def topic(thread_id), do: "thread:" <> thread_id

  @doc "Starts the writer for `thread_id` unless it already runs."
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

  @doc "Stops the writer; the stored view stays in ETS."
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

  @doc """
  Forgets the given turns after a `thread/revert` and tells subscribers with
  a `thread/reverted` event carrying `"turnIds"`. Clients should re-snapshot.
  """
  @spec drop_turns(String.t(), [String.t()]) :: :ok
  def drop_turns(thread_id, turn_ids), do: GenServer.call(via(thread_id), {:drop_turns, turn_ids})

  @doc "Reads the stored view directly from ETS."
  @spec snapshot(String.t()) :: snapshot
  def snapshot(thread_id), do: Store.snapshot(thread_id)

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
  def init(thread_id), do: {:ok, thread_id}

  # One event the store cannot fold (a shape that changed under us) is
  # dropped with a log line: crashing here would restart this writer for
  # every delta of the stream and escalate up the tree — never let a single
  # event take the thread's view down.
  @impl true
  def handle_cast({:ingest, method, params}, thread_id) do
    seq = Store.event(thread_id, fn -> Store.fold(thread_id, method, params) end)
    PubSub.broadcast(@pubsub, topic(thread_id), {:thread, seq, method, params})
    {:noreply, thread_id}
  rescue
    e ->
      Logger.error(
        "thread state #{thread_id}: could not fold #{method}: #{Exception.message(e)}; params: #{inspect(params, limit: 20)}"
      )

      {:noreply, thread_id}
  end

  # a request names its thread like every other event: the Tracker (the
  # notify feed) and the channel route on it
  def handle_cast({:put_request, id, method, params}, thread_id) do
    seq = Store.event(thread_id, fn -> Store.put_request(thread_id, id, method, params) end)

    PubSub.broadcast(
      @pubsub,
      topic(thread_id),
      {:thread, seq, method,
       params |> Map.put("requestId", id) |> Map.put_new("threadId", thread_id)}
    )

    {:noreply, thread_id}
  end

  def handle_cast({:resolve_request, id}, thread_id) do
    seq = Store.event(thread_id, fn -> Store.delete_request(thread_id, id) end)

    PubSub.broadcast(
      @pubsub,
      topic(thread_id),
      {:thread, seq, "serverRequest/resolved", %{"requestId" => id, "threadId" => thread_id}}
    )

    {:noreply, thread_id}
  end

  @impl true
  # a backfill means the agent was started again from its transcript: nothing
  # it was asked before can be answered any more
  def handle_call({:backfill, result}, _from, thread_id) do
    for %{id: id} <- Store.requests(thread_id) do
      Store.delete_request(thread_id, id)
      broadcast(thread_id, "serverRequest/resolved", %{"requestId" => id})
    end

    {:reply, Store.backfill(thread_id, result), thread_id}
  end

  def handle_call({:drop_turns, turn_ids}, _from, thread_id) do
    seq = Store.event(thread_id, fn -> Store.delete_turns(thread_id, turn_ids) end)

    PubSub.broadcast(
      @pubsub,
      topic(thread_id),
      {:thread, seq, "thread/reverted", %{"threadId" => thread_id, "turnIds" => turn_ids}}
    )

    {:reply, :ok, thread_id}
  end

  defp broadcast(thread_id, method, params) do
    seq = Store.next_seq(thread_id)
    PubSub.broadcast(@pubsub, topic(thread_id), {:thread, seq, method, params})
  end
end
