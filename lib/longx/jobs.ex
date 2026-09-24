defmodule Longx.Jobs do
  @moduledoc """
  Background jobs, owned by Longx and named by the agent — its long commands
  (a server, a backtest that runs for an hour) without `nohup … &`: an agent
  once started twenty such and polled their logs, the processes orphans no
  ledger listed, and after a compaction nobody knew their pids.

  A job is `{thread_id, name}`: a name is one job at a time in a thread (a
  running one refuses another; a finished one is replaced by the next start).
  It runs in its own process (`Longx.Jobs.Job`) holding the command's shim;
  its directory `<dir>/<thread_id>/<name>/` keeps `job.json` (what it runs,
  its state and end) and its bounded log (`Longx.Jobs.Log`), so a finished
  job — and one a restart cut (`lost`) — reads back.

  Its end is told to the agent (`Longx.Agent.job_exited/2`) unless the agent
  saw it (a `wait` or an `output` that returned the end, a `stop`). A thread
  keeps its finished jobs for `keep_days` (7) and at most `keep_finished`
  (20) of them. `config :longx, Longx.Jobs, dir:` (dev `data/jobs`, prod
  `$LONGX_DATA_DIR/jobs`).
  """

  alias Longx.Jobs.{Job, Log}

  @supervisor Longx.Jobs.Supervisor
  @registry Longx.Jobs.Registry
  @name ~r/^[\p{L}\p{N}][\p{L}\p{N}._-]{0,63}$/u

  @type info :: %{
          name: String.t(),
          cmd: String.t(),
          status: String.t(),
          exit_code: integer | nil,
          reason: String.t() | nil,
          run: String.t()
        }

  @doc "PubSub topic of a thread's jobs: `{:job, info}` when one ends."
  def topic(thread_id), do: "jobs:" <> thread_id

  @doc """
  Starts `cmd` in the background as the thread's job `name`. Options: `cwd`,
  `shell` / `login`, `guards` (`oom_score_adj`, `memory_limit`, `floor`),
  `notify` (true), `on_exit` (the notice's receiver, the agent by default).
  """
  @spec start(String.t(), String.t(), String.t(), keyword) ::
          {:ok, info} | {:error, {:running, info} | :bad_name | term}
  def start(thread_id, name, cmd, opts \\ []) when is_binary(cmd) do
    cond do
      not (is_binary(name) and Regex.match?(@name, name)) ->
        {:error, :bad_name}

      pid = whereis(thread_id, name) ->
        {:error, {:running, GenServer.call(pid, :info)}}

      true ->
        prune(thread_id, opts)
        dir = job_dir(thread_id, name)
        File.rm_rf!(dir)
        File.mkdir_p!(dir)
        login? = Keyword.get(opts, :login, true) != false

        spec = %{
          thread_id: thread_id,
          name: name,
          cmd: cmd,
          cwd: Keyword.get(opts, :cwd) || File.cwd!(),
          dir: dir,
          run: Ash.UUID.generate(),
          notify: Keyword.get(opts, :notify, true) != false,
          shell: Keyword.get(opts, :shell) || Longx.Agent.Tools.ShellEnv.shell(),
          flag: if(login?, do: "-lc", else: "-c"),
          env: Longx.Agent.Tools.ShellEnv.env_list(),
          guards: Keyword.get(opts, :guards, []),
          on_exit: Keyword.get(opts, :on_exit) || (&Longx.Agent.job_exited(thread_id, &1)),
          log_opts: Keyword.take(config(), [:head_bytes, :segment_bytes, :partial_bytes])
        }

        case DynamicSupervisor.start_child(@supervisor, {Job, spec}) do
          {:ok, pid} -> {:ok, GenServer.call(pid, :info)}
          {:error, {:already_started, pid}} -> {:error, {:running, GenServer.call(pid, :info)}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc "The thread's jobs: the running ones first, then the finished, latest first."
  @spec list(String.t()) :: [info]
  def list(thread_id) do
    thread_dir = Path.join(dir(), thread_id)

    case File.ls(thread_dir) do
      {:ok, names} ->
        names
        |> Enum.map(&info(thread_id, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.sort(
          &({&1.status == "running", &1.started_at || ""} >=
              {&2.status == "running", &2.started_at || ""})
        )

      {:error, _} ->
        []
    end
  end

  @doc "The running jobs of a thread (what a compaction's summary names)."
  @spec running(String.t()) :: [info]
  def running(thread_id), do: thread_id |> list() |> Enum.filter(&(&1.status == "running"))

  @doc """
  A job's output and state: `tail:` lines, `grep:` a substring. Reading the
  end of a finished job is the agent seeing it: it is not told again.
  """
  @spec output(String.t(), String.t(), keyword) ::
          {:ok, %{info: info, text: String.t(), stats: map}} | {:error, :unknown}
  def output(thread_id, name, opts \\ []) do
    case whereis(thread_id, name) do
      pid when is_pid(pid) ->
        {:ok, GenServer.call(pid, {:output, opts})}

      nil ->
        case info(thread_id, name) do
          nil ->
            {:error, :unknown}

          info ->
            info = observe(thread_id, info)
            log = Path.join(job_dir(thread_id, name), "log")
            {:ok, %{info: info, text: Log.read(log, opts), stats: Log.read_stats(log)}}
        end
    end
  catch
    :exit, _ -> output(thread_id, name, opts)
  end

  @doc "Waits for a job to end, at most `timeout` ms: its state then (an end seen is not told again)."
  @spec wait(String.t(), String.t(), non_neg_integer) :: {:ok, info} | {:error, :unknown}
  def wait(thread_id, name, timeout) do
    case whereis(thread_id, name) do
      pid when is_pid(pid) ->
        GenServer.call(pid, {:wait, timeout}, timeout + 5_000)

      nil ->
        case info(thread_id, name) do
          nil -> {:error, :unknown}
          info -> {:ok, observe(thread_id, info)}
        end
    end
  catch
    :exit, _ -> wait(thread_id, name, 0)
  end

  @doc "Stops a job: its whole process tree ends; the agent knows, it is not told."
  @spec stop(String.t(), String.t()) :: {:ok, info} | {:error, :unknown}
  def stop(thread_id, name) do
    case whereis(thread_id, name) do
      pid when is_pid(pid) ->
        GenServer.call(pid, :stop, 30_000)

      nil ->
        case info(thread_id, name) do
          nil -> {:error, :unknown}
          info -> {:ok, info}
        end
    end
  catch
    :exit, _ -> stop(thread_id, name)
  end

  @doc "Whether the agent has seen this run's end."
  @spec observed?(String.t(), String.t(), String.t()) :: boolean
  def observed?(thread_id, name, run) do
    case info(thread_id, name) do
      %{run: ^run, observed: observed} -> observed == true
      # replaced by a later run: this one's end no longer matters
      _ -> true
    end
  end

  @doc "Stops every job of a thread (its archive)."
  @spec stop_all(String.t()) :: :ok
  def stop_all(thread_id) do
    for %{name: name, status: "running"} <- list(thread_id), do: stop(thread_id, name)
    :ok
  end

  @doc "Stops a thread's jobs and removes their directories (the thread deleted)."
  @spec delete(String.t()) :: :ok
  def delete(thread_id) do
    stop_all(thread_id)
    File.rm_rf!(Path.join(dir(), thread_id))
    :ok
  end

  @doc "A boot: every job the previous run left running is `lost` (its process died with Longx). Answers how many."
  @spec settle_after_restart() :: non_neg_integer
  def settle_after_restart do
    for thread <- ls(dir()),
        name <- ls(Path.join(dir(), thread)),
        info = info(thread, name),
        info && info.status == "running" && whereis(thread, name) == nil,
        reduce: 0 do
      n ->
        save_info(job_dir(thread, name), %{
          info
          | status: "lost",
            reason: "Longx restarted while it ran; it did not finish",
            finished_at: DateTime.utc_now() |> DateTime.to_iso8601()
        })

        n + 1
    end
  end

  @doc "Drops a thread's finished jobs past `keep_days` and beyond the latest `keep_finished`."
  @spec prune(String.t(), keyword) :: :ok
  def prune(thread_id, opts \\ []) do
    keep = Keyword.get(opts, :keep_finished, config()[:keep_finished] || 20)
    days = Keyword.get(opts, :keep_days, config()[:keep_days] || 7)
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 86_400) |> DateTime.to_iso8601()

    finished = thread_id |> list() |> Enum.filter(&(&1.status != "running"))

    {kept, old} = Enum.split(finished, keep)
    expired = Enum.filter(kept, &(is_binary(&1.finished_at) and &1.finished_at < cutoff))

    for %{name: name} <- old ++ expired, do: File.rm_rf!(job_dir(thread_id, name))
    :ok
  end

  @doc false
  def save_info(dir, info), do: File.write!(Path.join(dir, "job.json"), Jason.encode!(info))

  defp observe(thread_id, %{observed: false, status: status} = info) when status != "running" do
    info = %{info | observed: true}
    save_info(job_dir(thread_id, info.name), info)
    info
  end

  defp observe(_thread_id, info), do: info

  defp info(thread_id, name) do
    with {:ok, json} <- File.read(Path.join(job_dir(thread_id, name), "job.json")),
         {:ok, map} <- Jason.decode(json) do
      %{
        name: map["name"] || name,
        cmd: map["cmd"],
        cwd: map["cwd"],
        status: map["status"],
        exit_code: map["exit_code"],
        reason: map["reason"],
        run: map["run"],
        notify: map["notify"] != false,
        observed: map["observed"] == true,
        started_at: map["started_at"],
        finished_at: map["finished_at"]
      }
    else
      _ -> nil
    end
  end

  defp whereis(thread_id, name) do
    case Registry.lookup(@registry, {thread_id, name}) do
      [{pid, _}] -> if Process.alive?(pid), do: pid
      [] -> nil
    end
  end

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, names} -> names
      {:error, _} -> []
    end
  end

  defp job_dir(thread_id, name), do: Path.join([dir(), thread_id, name])

  @doc "Where the jobs live (`config :longx, Longx.Jobs, dir:`)."
  def dir, do: config()[:dir] || Path.expand("data/jobs")

  defp config, do: Application.get_env(:longx, __MODULE__, [])
end
