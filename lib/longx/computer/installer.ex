defmodule Longx.Computer.Installer do
  @moduledoc "Single-flight, asynchronous CUA Driver downloads for Settings."
  use GenServer

  alias Longx.Computer.Runtime

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def topic, do: "computer_install"
  def status, do: GenServer.call(__MODULE__, :status)
  def install, do: GenServer.call(__MODULE__, :install)
  def reset, do: GenServer.call(__MODULE__, :reset)

  @impl true
  def init(_opts), do: {:ok, %{stage: :idle, received: 0, total: nil, error: nil, task: nil}}

  @impl true
  def handle_call(:status, _from, state), do: {:reply, public(state), state}

  def handle_call(:reset, _from, %{task: nil} = state),
    do: {:reply, :ok, %{state | stage: :idle, received: 0, total: nil, error: nil}}

  def handle_call(:reset, _from, state), do: {:reply, :ok, state}
  def handle_call(:install, _from, %{task: %Task{}} = state), do: {:reply, :ok, state}

  def handle_call(:install, _from, state) do
    target = Runtime.current_target()

    cond do
      is_nil(target) ->
        {:reply, {:error, :unsupported_platform}, state}

      match?({:ok, :env, _, _}, Runtime.resolve(target)) or Runtime.installed?(target) ->
        {:reply, :ok, publish(%{state | stage: :installed, error: nil})}

      true ->
        server = self()

        task =
          Task.Supervisor.async_nolink(Longx.Computer.TaskSupervisor, fn ->
            Runtime.install(target,
              source: {:url, Runtime.config(:download_url) || Runtime.asset_url(target)},
              sha256: Runtime.config(:download_sha256) || Runtime.sha256(target),
              progress: fn {received, total} ->
                GenServer.cast(server, {:progress, received, total})
              end,
              on_stage: fn stage -> GenServer.cast(server, {:stage, stage}) end
            )
          end)

        {:reply, :ok,
         publish(%{state | task: task, stage: :downloading, received: 0, total: nil, error: nil})}
    end
  end

  @impl true
  def handle_cast({:progress, received, total}, %{task: %Task{}} = state),
    do: {:noreply, publish(%{state | received: received, total: total})}

  def handle_cast({:stage, stage}, %{task: %Task{}} = state)
      when stage in [:verifying, :extracting],
      do: {:noreply, publish(%{state | stage: stage})}

  def handle_cast(_message, state), do: {:noreply, state}

  @impl true
  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    state =
      case result do
        {:ok, _path} -> %{state | task: nil, stage: :installed, error: nil}
        {:error, reason} -> %{state | task: nil, stage: :failed, error: describe(reason)}
      end

    {:noreply, publish(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state),
    do:
      {:noreply,
       publish(%{
         state
         | task: nil,
           stage: :failed,
           error: "download crashed: #{inspect(reason)}"
       })}

  def handle_info(_message, state), do: {:noreply, state}

  defp publish(state) do
    Phoenix.PubSub.broadcast(Longx.PubSub, topic(), {:computer_install, public(state)})
    state
  end

  defp public(state) do
    target = Runtime.current_target()

    {source, path, version} =
      case Runtime.resolve(target) do
        {:ok, source, path, version} -> {source, path, version}
        _ -> {nil, nil, nil}
      end

    app = if path, do: Runtime.app_path(path, target)

    %{
      stage: if(state.stage == :idle and path != nil, do: :installed, else: state.stage),
      received: state.received,
      total: state.total,
      error: state.error,
      version: Runtime.version(),
      latest: Runtime.version(),
      target: target,
      path: path,
      app_path: if(app && File.dir?(app), do: app),
      source: source,
      installed_version: version,
      download_size: Runtime.download_size(target),
      upgradable: source == :downloaded and Version.compare(version, Runtime.version()) == :lt
    }
  end

  defp describe({:checksum_mismatch, _}), do: "the archive does not match its pinned checksum"
  defp describe({:download_failed, {:status, status}}), do: "download failed (HTTP #{status})"
  defp describe({:download_failed, %{__exception__: true} = error}), do: Exception.message(error)
  defp describe({:extract_failed, reason}), do: "could not unpack the driver: #{inspect(reason)}"
  defp describe(reason), do: inspect(reason)
end
