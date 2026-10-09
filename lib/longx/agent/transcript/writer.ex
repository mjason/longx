defmodule Longx.Agent.Transcript.Writer do
  @moduledoc """
  The one process that writes transcript items — the agents' event log.

  SQLite takes one writer at a time: a team of agents each appending its
  items as they came, beside the Tracker's row writes, met "database is
  locked" (and a raise there ended an agent mid-turn). So an agent never
  writes its transcript itself: `Longx.Agent.Transcript.append!/1` hands
  the item to this process (a cast — the loop goes on at once) and this
  process writes whatever has accumulated in **one transaction**, then the
  next batch, and so on; the items of one thread keep their order (one
  mailbox, one queue). A read, a truncate or a delete flushes first
  (`flush/0`, a call answered after everything queued before it), so
  nothing ever reads around a pending item.

  A batch the database temporarily refuses is tried again after a wait (`waits:`).
  Exhausting the short retry window keeps the batch queued and reports the
  outage; a synchronous flush fails rather than pretending that data was saved.
  An error
  that is no lock is a bug — the batch is dropped, recorded as a
  `Longx.System.Faults` entry and logged, and the writer lives on.
  """

  use GenServer
  require Logger

  alias Longx.Agent.Transcript.Item

  @lock_waits [200, 500, 1_000, 2_000, 2_000, 2_000]

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)

    if name,
      do: GenServer.start_link(__MODULE__, opts, name: name),
      else: GenServer.start_link(__MODULE__, opts)
  end

  @doc "Queues an item (an agent's event); written by the next batch."
  @spec append(map) :: :ok
  def append(attrs) when is_map(attrs), do: GenServer.cast(__MODULE__, {:append, attrs})

  @doc "Everything queued before this call is written (or dropped as a bug) when it answers."
  @spec flush() :: :ok | {:error, term}
  def flush, do: GenServer.call(__MODULE__, :flush, 60_000)

  @doc "Counters (tests, the settings page): batches written, items written, items dropped."
  @spec stats() :: %{batches: non_neg_integer, written: non_neg_integer, dropped: non_neg_integer}
  def stats, do: GenServer.call(__MODULE__, :stats)

  @impl true
  def init(opts) do
    {:ok,
     %{
       pending: [],
       scheduled: false,
       waits: Keyword.get(opts, :waits, @lock_waits),
       left: nil,
       stalled: false,
       write: Keyword.get(opts, :write, &write_batch/1),
       batches: 0,
       written: 0,
       dropped: 0
     }}
  end

  @impl true
  def handle_cast({:append, attrs}, state) do
    # A disconnect can hide a successful commit. Keep the same key through
    # retries, so replaying that batch never duplicates transcript items.
    attrs = Map.put_new_lazy(attrs, :id, &Ash.UUID.generate/0)
    {:noreply, schedule(%{state | pending: [attrs | state.pending]})}
  end

  # the flush message lands behind every append that was in the mailbox when
  # it was sent: one batch per burst, with no timer to tune
  defp schedule(%{scheduled: true} = state), do: state

  defp schedule(state) do
    send(self(), :flush)
    %{state | scheduled: true}
  end

  @impl true
  def handle_info(:flush, state), do: {:noreply, write(%{state | scheduled: false}, :async)}

  # a flush call waits through the lock waits itself (the caller is about to
  # read); the timer path retries one wait at a time so the mailbox keeps
  # draining between tries
  @impl true
  def handle_call(:flush, _from, state) do
    state = write(%{state | scheduled: false}, :sync)
    {:reply, if(state.pending == [], do: :ok, else: {:error, :locked}), state}
  end

  def handle_call(:stats, _from, state),
    do: {:reply, Map.take(state, [:batches, :written, :dropped]), state}

  defp write(%{pending: []} = state, _mode), do: state

  defp write(%{pending: pending, write: write} = state, mode) do
    batch = Enum.reverse(pending)

    case attempt(write, batch, state.left || state.waits) do
      {:ok, n} ->
        %{
          state
          | pending: [],
            left: nil,
            stalled: false,
            batches: state.batches + 1,
            written: state.written + n
        }

      {:locked, e, []} ->
        unless state.stalled do
          Logger.error(
            "transcript writer: keeping #{length(batch)} queued items after transient database failure: #{Exception.message(e)}"
          )

          Longx.System.Faults.record(
            :db,
            "transcript",
            "#{length(batch)} transcript items are queued for retry: database temporarily unavailable"
          )
        end

        Process.send_after(self(), :flush, 2_000)
        %{state | left: [], scheduled: true, stalled: true}

      {:locked, _e, [wait | rest]} when mode == :sync ->
        Process.sleep(wait)
        write(%{state | left: rest}, :sync)

      {:locked, _e, [wait | rest]} ->
        Process.send_after(self(), :flush, wait)
        %{state | left: rest, scheduled: true}

      {:error, e} ->
        Logger.error(
          "transcript writer: dropping #{length(batch)} items: #{Exception.message(e)}"
        )

        Longx.System.Faults.record(
          :db,
          "transcript",
          "#{length(batch)} transcript items dropped: #{Exception.message(e)}"
        )

        %{state | pending: [], left: nil, dropped: state.dropped + length(batch)}
    end
  end

  defp attempt(write, batch, waits) do
    write.(batch)
  rescue
    e ->
      if locked?(e), do: {:locked, e, waits}, else: {:error, e}
  end

  # one transaction for the whole batch, managed by Ash (a Repo.transaction of
  # our own around Ash.create! makes Ash warn about every missed notification)
  defp write_batch(batch) do
    %Ash.BulkResult{status: :success} =
      Ash.bulk_create!(batch, Item, :append,
        upsert?: true,
        upsert_fields: [],
        transaction: :all,
        return_records?: false,
        notify?: false,
        stop_on_error?: true,
        return_errors?: true
      )

    {:ok, length(batch)}
  end

  # SQLite's lock, or the pool's wait for a connection running out behind it
  defp locked?(e) do
    text = Exception.message(e) <> inspect(e)

    text =~ "database is locked" or text =~ "timed out because it queued" or
      text =~ "Database busy" or text =~ "request was dropped from queue" or
      text =~ "connection is closed because of an error, disconnect or timeout" or
      match?(%Exqlite.Error{message: "interrupted"}, e)
  end
end
