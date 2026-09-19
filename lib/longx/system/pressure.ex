defmodule Longx.System.Pressure do
  @moduledoc """
  The machine-level memory watchdog: every `tick` (2 s) it reads
  `Longx.System.Memory` and, when the free share has fallen under a running
  command's floor, tells that command to die — `{:memory_pressure, %{percent,
  available, total}}` to the process that registered it (`Plugs.Shell`'s tool
  task), which kills its shim tree and hands the model the reason.

  Why not RLIMIT alone: a GPU backtest on a DGX Spark took ~100 GB the NVIDIA
  driver carved out of RAM — no process's RSS, so neither `RLIMIT_AS` nor a
  cgroup saw it; the kernel's OOM killer went for Firefox and the box had to
  be rebooted. `MemAvailable` does see it. Every command runs through the
  shim, so what is killed is exactly what the agent started.

  Commands register in `Longx.System.Pressure.Registry` (duplicate keys under
  `:running`; an entry dies with its process) with their floor — the setting's
  `memory_floor_percent`, per project — so a project may run without the
  guard while another keeps it. Each kill is a `Longx.System.Faults` entry
  (`:memory`) the settings page lists and the status strip counts.
  """

  use GenServer
  require Logger

  alias Longx.System.{Faults, Memory}

  @registry Longx.System.Pressure.Registry
  @tick 2_000

  @type entry :: %{
          shim: pid | nil,
          floor: non_neg_integer,
          cmd: String.t(),
          thread_id: String.t() | nil
        }

  def registry, do: @registry

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Registers the calling process as running a command (its floor in percent; 0 = never killed)."
  @spec register(entry) :: :ok
  def register(%{floor: floor} = entry) when is_integer(floor) do
    {:ok, _} = Registry.register(@registry, :running, entry)
    :ok
  end

  @doc "Every registered command: `{pid, entry}`."
  @spec running() :: [{pid, entry}]
  def running, do: Registry.lookup(@registry, :running)

  @doc """
  One pass over the registered commands with the given memory reading:
  every command whose floor is above the free share is told; how many were.
  """
  @spec sweep(Memory.t() | nil) :: non_neg_integer
  def sweep(nil), do: 0

  def sweep(%{total: total, available: available}) when total > 0 do
    percent = div(available * 100, total)

    victims =
      Enum.filter(running(), fn {_pid, %{floor: floor}} -> floor > 0 and percent < floor end)

    Enum.each(victims, fn {pid, entry} ->
      Faults.record(
        :memory,
        "exec_command",
        "free memory down to #{percent}% (#{human(available)} of #{human(total)}): killed `#{clip(entry.cmd)}`" <>
          if(entry.thread_id, do: " (thread #{entry.thread_id})", else: "")
      )

      send(pid, {:memory_pressure, %{percent: percent, available: available, total: total}})
    end)

    length(victims)
  end

  @doc "Bytes as the person reads them."
  @spec human(non_neg_integer) :: String.t()
  def human(bytes) when bytes >= 1024 * 1024 * 1024,
    do: "#{Float.round(bytes / (1024 * 1024 * 1024), 1)} GB"

  def human(bytes), do: "#{div(bytes, 1024 * 1024)} MB"

  defp clip(cmd) when byte_size(cmd) > 120, do: binary_part(cmd, 0, 120) <> "…"
  defp clip(cmd), do: cmd

  ## The clock

  @impl true
  def init(opts) do
    tick = Keyword.get(opts, :tick, @tick)
    if tick, do: Process.send_after(self(), :tick, tick)
    {:ok, %{tick: tick}}
  end

  @impl true
  def handle_info(:tick, %{tick: tick} = state) do
    # nothing to read when nothing runs: an idle machine costs nothing
    if running() != [], do: sweep(Memory.read())
    Process.send_after(self(), :tick, tick)
    {:noreply, state}
  end
end
