defmodule Longx.Browser.Pool do
  @moduledoc """
  Permits for the headless browser: at most `max_concurrent` obscura
  processes at a time, the rest wait in FIFO order up to `queue_timeout`.
  A permit is tied to the caller (monitored), so a caller that dies mid-fetch
  frees its slot. Nothing else lives here — the browser processes themselves
  are short-lived children of the callers (`Longx.Shim.run/2`), so an idle
  system has no browser running at all.

  `config :longx, Longx.Browser` — `max_concurrent:` (default
  `min(4, schedulers)`), `queue_timeout:` (default 10 s).
  """

  use GenServer

  @type status :: %{busy: non_neg_integer, waiting: non_neg_integer, max: pos_integer}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Runs `fun` under a permit. `{:error, :busy}` when none frees up within
  `queue_timeout` (option or config).
  """
  @spec run((-> result), keyword) :: result | {:error, :busy} when result: term
  def run(fun, opts \\ []) do
    timeout = Keyword.get(opts, :queue_timeout, config(:queue_timeout, 10_000))

    case checkout(timeout) do
      :ok ->
        try do
          fun.()
        after
          checkin()
        end

      {:error, :busy} = busy ->
        busy
    end
  end

  @doc false
  def checkout(timeout) do
    try do
      GenServer.call(__MODULE__, :checkout, timeout)
    catch
      :exit, {:timeout, _} ->
        GenServer.cast(__MODULE__, {:cancel, self()})
        {:error, :busy}
    end
  end

  @doc false
  def checkin, do: GenServer.cast(__MODULE__, {:checkin, self()})

  @spec status() :: status
  def status, do: GenServer.call(__MODULE__, :status)

  ## Server

  defstruct holders: %{}, waiting: :queue.new()

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  # read per request so a config change (tests, runtime tuning) applies at once
  defp max, do: config(:max_concurrent, min(4, System.schedulers_online()))

  @impl true
  def handle_call(:checkout, {pid, _} = from, state) do
    if map_size(state.holders) < max() do
      {:reply, :ok, grant(state, pid)}
    else
      {:noreply, %{state | waiting: :queue.in(from, state.waiting)}}
    end
  end

  def handle_call(:status, _from, state) do
    {:reply, %{busy: map_size(state.holders), waiting: :queue.len(state.waiting), max: max()},
     state}
  end

  @impl true
  def handle_cast({:checkin, pid}, state), do: {:noreply, release(state, pid)}

  def handle_cast({:cancel, pid}, state) do
    waiting = :queue.filter(fn {p, _} -> p != pid end, state.waiting)
    {:noreply, %{state | waiting: waiting}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do: {:noreply, release(state, pid)}

  defp grant(state, pid) do
    ref = Process.monitor(pid)
    %{state | holders: Map.put(state.holders, pid, ref)}
  end

  defp release(state, pid) do
    case Map.pop(state.holders, pid) do
      {nil, _} ->
        state

      {ref, holders} ->
        Process.demonitor(ref, [:flush])
        state = %{state | holders: holders}

        case :queue.out(state.waiting) do
          {{:value, {next, _} = from}, waiting} ->
            GenServer.reply(from, :ok)
            grant(%{state | waiting: waiting}, next)

          {:empty, _} ->
            state
        end
    end
  end

  defp config(key, default) do
    :longx |> Application.get_env(Longx.Browser, []) |> Keyword.get(key, default)
  end
end
