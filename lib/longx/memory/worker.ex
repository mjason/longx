defmodule Longx.Memory.Worker do
  @moduledoc """
  Runs the memory pipeline on a timer: a few idle threads distilled into
  notes (`Extract`, when the switch is on), then the pending notes folded
  into `MEMORY.md` (`Consolidate`). `config :longx, Longx.Memory, tick:`
  (default 15 min; nil = never on its own — tests), `idle_hours:`,
  `per_run:`. `run_now/1` runs one pass and answers with the report; the
  state file keeps the last run and its error for the page.
  """
  use GenServer

  require Logger

  alias Longx.Memory
  alias Longx.Memory.{Consolidate, Extract}

  @default_tick :timer.minutes(15)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "One pass now (`complete:` overrides the model call — tests)."
  @spec run_now(keyword) ::
          {:ok,
           %{extracted: non_neg_integer, notes: non_neg_integer, consolidated: non_neg_integer}}
          | {:error, term}
  def run_now(opts \\ []) do
    dir = Keyword.get(opts, :dir, Memory.dir())
    config = Application.get_env(:longx, Longx.Memory, [])
    idle_hours = Keyword.get(opts, :idle_hours, Keyword.get(config, :idle_hours, 1))
    per_run = Keyword.get(opts, :per_run, Keyword.get(config, :per_run, 2))
    model = Keyword.take(opts, [:complete])

    result =
      with {:ok, extracted, notes} <- extract(dir, idle_hours, per_run, model),
           {:ok, folded} <- Consolidate.run(dir, model) do
        {:ok, %{extracted: extracted, notes: notes, consolidated: folded}}
      end

    :ok = Memory.record_run(dir, error_text(result))
    result
  end

  defp extract(dir, idle_hours, per_run, model) do
    if Memory.status(dir).auto_extract do
      Extract.candidates(idle_hours: idle_hours, limit: per_run)
      |> Enum.reduce_while({:ok, 0, 0}, fn thread, {:ok, threads, notes} ->
        case Extract.run(thread, [dir: dir] ++ model) do
          {:ok, n} -> {:cont, {:ok, threads + 1, notes + n}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    else
      {:ok, 0, 0}
    end
  end

  defp error_text({:ok, _}), do: nil
  defp error_text({:error, reason}), do: inspect(reason)

  @impl true
  def init(opts) do
    tick =
      Keyword.get(
        opts,
        :tick,
        Keyword.get(Application.get_env(:longx, Longx.Memory, []), :tick, @default_tick)
      )

    if tick, do: Process.send_after(self(), :tick, tick)
    {:ok, %{tick: tick}}
  end

  @impl true
  def handle_info(:tick, %{tick: tick} = state) do
    case run_now() do
      {:ok, report} -> Logger.debug("memory pipeline: #{inspect(report)}")
      {:error, reason} -> Logger.warning("memory pipeline failed: #{inspect(reason)}")
    end

    Process.send_after(self(), :tick, tick)
    {:noreply, state}
  end
end
