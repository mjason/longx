defmodule Longx.Codex.Pool do
  @moduledoc """
  One codex-app-server per project, started on first use.

  Each project gets its own `Longx.Codex.Worker` (supervisor + connection)
  and its own `CODEX_HOME` under `Longx.Codex.Home.default_dir/0`, keyed by
  the project id. A crash-looping codex takes down only its own worker; a
  later `connection/1` starts it again. Threads are found through the
  registry (`connection_for_thread/1`) once their connection has seen them.

  Configuration (`config :longx, Longx.Codex.Pool`):
    * `command:` — launch this instead of the bundled binary (tests)
    * `connection:` — extra `Longx.Codex.Connection` options
  """

  alias Longx.Codex.{Connection, Home, Worker}

  @registry Longx.Codex.Registry
  @supervisor __MODULE__.Supervisor

  @type project_id :: String.t()

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {DynamicSupervisor, :start_link, [[name: @supervisor, strategy: :one_for_one]]},
      type: :supervisor
    }
  end

  @doc "The project's connection, starting its codex if needed."
  @spec connection(project_id) :: {:ok, pid} | {:error, term}
  def connection(project_id) when is_binary(project_id) do
    case lookup(project_id) do
      {:ok, pid} -> {:ok, pid}
      :error -> start(project_id)
    end
  end

  @spec connection!(project_id) :: pid
  def connection!(project_id) do
    case connection(project_id) do
      {:ok, pid} -> pid
      {:error, reason} -> raise "cannot start codex for project #{project_id}: #{inspect(reason)}"
    end
  end

  @doc "The connection hosting a codex thread, if any running codex has touched it."
  @spec connection_for_thread(String.t()) :: {:ok, pid} | {:error, :no_connection}
  def connection_for_thread(thread_id) do
    case Registry.lookup(@registry, {:thread, thread_id}) do
      [{pid, _tag}] -> if Process.alive?(pid), do: {:ok, pid}, else: {:error, :no_connection}
      [] -> {:error, :no_connection}
    end
  end

  @doc "`:stopped`, or the running connection's `Connection.info/1`."
  @spec status(project_id) :: :stopped | map
  def status(project_id) do
    case lookup(project_id) do
      {:ok, pid} -> Connection.info(pid)
      :error -> :stopped
    end
  end

  @doc "Project ids with a running worker."
  @spec running() :: [project_id]
  def running do
    Registry.select(@registry, [{{{:worker, :"$1"}, :_, :_}, [], [:"$1"]}])
  end

  @doc "Stops the project's codex. `:ok` when it was not running."
  @spec stop(project_id, keyword) :: :ok
  def stop(project_id, _opts \\ []) do
    case Registry.lookup(@registry, {:worker, project_id}) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(@supervisor, pid) |> ignore_not_found()
      [] -> :ok
    end
  end

  @doc "Stops and starts the project's codex; returns the new connection."
  @spec restart(project_id) :: {:ok, pid} | {:error, term}
  def restart(project_id) do
    :ok = stop(project_id)
    start(project_id)
  end

  @doc "The project's `CODEX_HOME`."
  @spec home_dir(project_id) :: Path.t()
  def home_dir(project_id), do: Path.join(Home.default_dir(), project_id)

  # the registry drops a dead process asynchronously: a pid that is already
  # gone (codex just crashed, the supervisor is restarting it) is not a hit
  defp lookup(project_id) do
    case Registry.lookup(@registry, {:connection, project_id}) do
      [{pid, _}] -> if Process.alive?(pid), do: {:ok, pid}, else: :error
      [] -> :error
    end
  end

  defp start(project_id, attempts \\ 2) do
    spec = {Worker, project_id: project_id, home_dir: home_dir(project_id), connection: launch()}

    case DynamicSupervisor.start_child(@supervisor, spec) do
      {:ok, worker} ->
        await_connection(project_id, worker)

      # a worker exists: it is either bringing its connection up or on its
      # way out (restart budget exhausted, or being stopped) — wait and see
      {:error, {:already_started, worker}} ->
        case await_connection(project_id, worker) do
          {:error, :worker_exited} when attempts > 0 -> start(project_id, attempts - 1)
          other -> other
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # the connection registers itself in init; give it a moment to appear,
  # unless the worker dies first
  @await_timeout :timer.seconds(30)

  defp await_connection(project_id, worker) do
    ref = Process.monitor(worker)
    result = await_loop(project_id, ref, System.monotonic_time(:millisecond) + @await_timeout)
    Process.demonitor(ref, [:flush])
    result
  end

  defp await_loop(project_id, ref, deadline) do
    case lookup(project_id) do
      {:ok, pid} ->
        {:ok, pid}

      :error ->
        receive do
          {:DOWN, ^ref, :process, _worker, _reason} -> {:error, :worker_exited}
        after
          20 ->
            if System.monotonic_time(:millisecond) < deadline,
              do: await_loop(project_id, ref, deadline),
              else: {:error, :not_started}
        end
    end
  end

  defp launch do
    config = Application.get_env(:longx, __MODULE__, [])

    case Keyword.fetch(config, :command) do
      {:ok, command} ->
        Keyword.merge([command: command, env: []], Keyword.get(config, :connection, []))

      :error ->
        Keyword.get(config, :connection, [])
    end
  end

  defp ignore_not_found(:ok), do: :ok
  defp ignore_not_found({:error, :not_found}), do: :ok
end
