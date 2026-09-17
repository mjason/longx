defmodule Longx.Browser.Installer do
  @moduledoc """
  Downloads the headless browser (`Longx.Browser.Runtime`) on demand into
  the data directory — one download at a time, a second `install/0` joins
  the one in flight — and tells everyone how it goes: `status/0` and
  `{:browser_install, status}` on `topic/0`, stages `:idle` →
  `:downloading` (with `received` / `total` bytes) → `:verifying` →
  `:extracting` → `:installed`, or `:failed` with the reason (nothing
  half-written stays: `Longx.Bundle` unpacks into a staging directory and
  swaps it in whole). The first `Longx.Browser.fetch/2` with no browser
  starts it. `config :longx, Longx.Browser` — `download_url:` /
  `download_sha256:` stand in for the pinned release (tests).
  """

  use GenServer

  require Logger

  alias Longx.Browser.Runtime

  @topic "browser_install"
  @stages ~w(idle downloading verifying extracting installed failed)a

  @type status :: %{
          stage: :idle | :downloading | :verifying | :extracting | :installed | :failed,
          received: non_neg_integer,
          total: non_neg_integer | nil,
          error: String.t() | nil,
          version: String.t(),
          target: String.t() | nil,
          path: Path.t() | nil
        }

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Starts the download unless one runs (then joins it) or the browser is installed."
  @spec install() :: :ok | {:error, :unsupported_platform}
  def install, do: GenServer.call(__MODULE__, :install)

  @doc "The stage now, plus what is installed."
  @spec status() :: status
  def status, do: GenServer.call(__MODULE__, :status)

  @doc "Forgets a finished or failed run (a retry starts over; tests)."
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  @spec stages() :: [atom]
  def stages, do: @stages

  @impl true
  def init(_opts), do: {:ok, %{stage: :idle, received: 0, total: nil, error: nil, task: nil}}

  @impl true
  def handle_call(:status, _from, state), do: {:reply, public(state), state}

  def handle_call(:reset, _from, %{task: nil} = state),
    do: {:reply, :ok, %{state | stage: :idle, received: 0, total: nil, error: nil}}

  def handle_call(:reset, _from, state), do: {:reply, :ok, state}

  def handle_call(:install, _from, %{task: %Task{}} = state), do: {:reply, :ok, state}

  def handle_call(:install, _from, state) do
    case Runtime.current_target() do
      nil ->
        {:reply, {:error, :unsupported_platform}, state}

      target ->
        if Runtime.installed?(target) do
          {:reply, :ok, stage(%{state | task: nil}, :installed)}
        else
          server = self()

          task =
            Task.Supervisor.async_nolink(Longx.Browser.TaskSupervisor, fn ->
              Runtime.install(target,
                source: {:url, config(:download_url) || Runtime.asset_url(target)},
                sha256: config(:download_sha256) || elem(Runtime.sha256(target), 1),
                progress: fn {received, total} ->
                  GenServer.cast(server, {:progress, received, total})
                end,
                on_stage: fn s -> GenServer.cast(server, {:stage, s}) end
              )
            end)

          Logger.info("browser: downloading obscura #{Runtime.version()} (#{target})")

          {:reply, :ok,
           stage(%{state | task: task, received: 0, total: nil, error: nil}, :downloading)}
        end
    end
  end

  @impl true
  def handle_cast({:progress, received, total}, %{stage: :downloading} = state),
    do: {:noreply, stage(%{state | received: received, total: total}, :downloading)}

  def handle_cast({:progress, _, _}, state), do: {:noreply, state}
  def handle_cast({:stage, s}, state) when s in @stages, do: {:noreply, stage(state, s)}

  @impl true
  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, path} ->
        Logger.info("browser: installed #{path}")
        {:noreply, stage(%{state | task: nil, error: nil}, :installed)}

      {:error, reason} ->
        Logger.warning("browser: download failed: #{describe(reason)}")
        {:noreply, stage(%{state | task: nil, error: describe(reason)}, :failed)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state),
    do:
      {:noreply,
       stage(%{state | task: nil, error: "download crashed: #{inspect(reason)}"}, :failed)}

  def handle_info(_other, state), do: {:noreply, state}

  defp stage(state, s) do
    state = %{state | stage: s}
    Phoenix.PubSub.broadcast(Longx.PubSub, @topic, {:browser_install, public(state)})
    state
  end

  defp public(state) do
    target = Runtime.current_target()

    %{
      stage: state.stage,
      received: state.received,
      total: state.total,
      error: state.error,
      version: Runtime.version(),
      target: target,
      path:
        case Runtime.executable(target) do
          {:ok, path} -> path
          _ -> nil
        end
    }
  end

  defp describe({:download_failed, {:status, status}}), do: "download failed (HTTP #{status})"

  defp describe({:download_failed, %{__exception__: true} = e}),
    do: "download failed: " <> Exception.message(e)

  defp describe({:download_failed, reason}), do: "download failed: #{inspect(reason)}"
  defp describe({:checksum_mismatch, _}), do: "the archive does not match its pinned checksum"
  defp describe({:extract_failed, reason}), do: "could not unpack the archive: #{inspect(reason)}"
  defp describe(reason), do: inspect(reason)

  defp config(key), do: :longx |> Application.get_env(Longx.Browser, []) |> Keyword.get(key)
end
