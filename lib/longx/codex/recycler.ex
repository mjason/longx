defmodule Longx.Codex.Recycler do
  @moduledoc """
  Retires codex processes before they get old and fat.

  A long-lived app-server grows (openai/codex#42738: 11 GB RSS after 66 h,
  then every command spawn is CPU-bound copying its page tables), so every
  sweep looks at each running `Longx.Codex.Pool` worker and stops the ones
  that are **idle** (no turn in flight) and past a threshold; the next use
  starts a fresh process, and threads resume from codex's sqlite. A busy
  worker is never touched. Each sweep also publishes every worker's numbers
  as telemetry `[:longx, :codex, :worker, :sample]` (the UI's resource view).

  A codex nobody talks to still costs its memory: a worker whose last turn
  ended `idle_after_ms` ago (a fresh one: since it started) is stopped too —
  the next message to any of its threads starts it again and resumes the
  thread (a second or two), which is what a project someone left for the
  day should cost.

  `config :longx, Longx.Codex.Recycler`:
    * `tick:` — sweep interval (default 5 min)
    * `idle_after_ms:` — default 30 min; nil never
    * `max_uptime_ms:` — default 12 h
    * `max_rss_bytes:` — the whole tree, default 2 GiB
    * `max_turns:` — default 200
  """

  use GenServer

  alias Longx.Codex.Pool

  require Logger

  @defaults [
    tick: :timer.minutes(5),
    idle_after_ms: :timer.minutes(30),
    max_uptime_ms: :timer.hours(12),
    max_rss_bytes: 2 * 1024 * 1024 * 1024,
    max_turns: 200
  ]

  @type verdict :: {Pool.project_id(), :recycled | :kept | :busy, atom | nil}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The idle limit in force (`idle_after_ms:`), nil when workers are never stopped for idleness."
  @spec idle_after_ms() :: pos_integer | nil
  def idle_after_ms, do: config(:idle_after_ms)

  @doc "One sweep, now: what happened to each running worker."
  @spec sweep() :: [verdict]
  def sweep, do: GenServer.call(__MODULE__, :sweep, :timer.seconds(30))

  @impl true
  def init(_opts) do
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_call(:sweep, _from, state), do: {:reply, do_sweep(), state}

  @impl true
  def handle_info(:tick, state) do
    do_sweep()
    schedule()
    {:noreply, state}
  end

  defp do_sweep do
    for project_id <- Pool.running(),
        info = Pool.status(project_id),
        is_map(info) do
      sample(project_id, info)
      judge(project_id, info)
    end
  end

  defp judge(project_id, %{active_turns: n}) when n > 0, do: {project_id, :busy, nil}

  defp judge(project_id, info) do
    case exceeded(info) do
      nil ->
        {project_id, :kept, nil}

      reason ->
        Logger.info("codex recycler: stopping idle codex of project #{project_id} (#{reason})")
        :ok = Pool.stop(project_id)
        {project_id, :recycled, reason}
    end
  end

  defp exceeded(info) do
    cond do
      uptime_ms(info) > config(:max_uptime_ms) -> :max_uptime
      rss(info) > config(:max_rss_bytes) -> :max_rss
      info.turns >= config(:max_turns) -> :max_turns
      idle?(info) -> :idle
      true -> nil
    end
  end

  defp sample(project_id, info) do
    measurements = %{
      rss_bytes: rss(info),
      processes: (info.stats || %{})[:processes] || 0,
      cpu_ms: (info.stats || %{})[:cpu_ms] || 0,
      uptime_ms: uptime_ms(info),
      turns: info.turns,
      active_turns: info.active_turns
    }

    :telemetry.execute([:longx, :codex, :worker, :sample], measurements, %{
      project_id: project_id,
      os_pid: info.os_pid
    })

    # the project page shows the same numbers live (LongxWeb.ProjectChannel)
    Phoenix.PubSub.broadcast(
      Longx.PubSub,
      "project:" <> project_id,
      {:codex_sample, project_id, measurements}
    )
  end

  # nothing ran for idle_after_ms (a worker that never ran a turn: since it started)
  defp idle?(info) do
    case config(:idle_after_ms) do
      nil ->
        false

      limit ->
        since = Map.get(info, :last_turn_at) || info.started_at

        is_struct(since, DateTime) and
          DateTime.diff(DateTime.utc_now(), since, :millisecond) > limit
    end
  end

  defp rss(%{stats: %{rss_bytes: rss}}), do: rss
  defp rss(_info), do: 0

  defp uptime_ms(%{started_at: %DateTime{} = started}),
    do: DateTime.diff(DateTime.utc_now(), started, :millisecond)

  defp uptime_ms(_info), do: 0

  defp schedule, do: Process.send_after(self(), :tick, config(:tick))

  defp config(key) do
    :longx
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, Keyword.fetch!(@defaults, key))
  end
end
