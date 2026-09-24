defmodule Longx.Agent.Plugs.Jobs do
  @moduledoc """
  The agent's background jobs (`Longx.Jobs`), by name — never a pid it would
  have to remember across a compaction, never a `kill` aimed by guess:
  `start_job` (a long command in the background; its end wakes the agent),
  `jobs`, `job_output` (the kept start and latest lines, `tail` / `grep`),
  `wait_job` (up to 10 min), `stop_job` (the whole tree). An agent once ran
  twenty `nohup … &` backtests and `tail`ed their logs seventy-two times.

  In the shipped pipeline after Shell, with the same guards (`options
  Jobs, oom_score_adj:/memory_percent:/memory_floor_percent:` from the
  settings layer): the memory watchdog and the settings page's 进程 list
  cover a job as they cover a command.
  """

  use Longx.Agent.Plug

  alias Longx.Agent.Plugs.Shell

  @wait_default 60_000
  @wait_max 600_000
  @default_output_tokens 10_000
  @bytes_per_token 4

  tool :start_job,
       "Starts a long-running command — a server, a batch or a backtest that takes minutes or hours — in the background as a named job of this conversation, and returns at once. Longx keeps it: it goes on after this turn, its output is kept (the start and the latest ~2 MB; the middle of a huge output is dropped), and when it ends you are woken with its exit code and last lines — so start it, then end your turn or do other work; do not poll it. A name is one job at a time: a running job refuses another start under its name. Use this instead of backgrounding a command yourself (nohup, &, setsid).",
       show: :tool do
    param :name,
          :string,
          "A short name for the job, used to read, wait for or stop it: letters, digits, . _ - (up to 64).",
          required: true

    param :cmd, :string, "Shell command to run.", required: true
    param :workdir, :string, "Working directory. Defaults to the turn cwd."

    param :notify,
          :boolean,
          "Wake you when it ends (default true). false for a job you will check yourself."
  end

  tool :jobs,
       "Lists this conversation's background jobs: name, state (running / exited / stopped / killed / lost), exit code, when it started and ended, its command." do
  end

  tool :job_output,
       "A job's output and state. The output kept is its start and its latest lines (the middle of a very long output is omitted, and said so). tail: only the last N lines; grep: only the lines containing this text." do
    param :name, :string, "The job's name.", required: true
    param :tail, :integer, "Only the last N lines."
    param :grep, :string, "Only the lines containing this text."
    param :max_output_tokens, :number, "Output token budget. Defaults to 10000 tokens."
  end

  tool :wait_job,
       "Waits for a job to end, at most timeout_ms (default 60000, max 600000), and returns its state and last lines. For a job that runs long, end your turn instead: you are woken when it ends.",
       timeout: @wait_max + 10_000 do
    param :name, :string, "The job's name.", required: true
    param :timeout_ms, :integer, "How long to wait at most (default 60000, max 600000)."
  end

  tool :stop_job,
       "Stops a job: its whole process tree ends. Stop a job this way, never with kill or pkill." do
    param :name, :string, "The job's name.", required: true
  end

  @impl true
  def init(opts), do: opts

  # start_job mounted with the machine's guards, as exec_command is
  @impl true
  def call(%Step{phase: :request} = step, opts) do
    g = Shell.guards(opts)
    guards = [oom_score_adj: g.oom_score_adj, memory_limit: g.memory_limit, floor: g.floor]
    start = Enum.find(__agent_tools__(), &(&1.name == "start_job"))

    step
    |> Longx.Agent.Plug.mount(__MODULE__)
    |> Step.tool(%{start | fun: fn args, ctx -> start_job(args, ctx, guards) end})
  end

  def call(step, _opts), do: step

  ## The tools

  def start_job(args, ctx), do: start_job(args, ctx, [])

  def start_job(_args, %{thread_id: nil}, _guards),
    do: {:error, "background jobs belong to a conversation; there is none here"}

  def start_job(%{"name" => name, "cmd" => cmd} = args, ctx, guards) do
    cwd = workdir(args["workdir"], ctx)
    notify = args["notify"] != false

    case Longx.Jobs.start(ctx.thread_id, name, cmd, cwd: cwd, notify: notify, guards: guards) do
      {:ok, _info} ->
        after_ =
          if notify,
            do:
              "It keeps running after this turn; you are woken when it ends, with its exit code and last lines — end your turn or do other work instead of polling.",
            else: "It will not wake you when it ends: check it with job_output or wait_job."

        {:ok,
         ~s|Job "#{name}" started in the background in #{cwd}. | <>
           after_ <> ~s| job_output(name: "#{name}") shows its output, stop_job stops it.|}

      {:error, {:running, info}} ->
        {:error,
         ~s|"#{name}" is already running (since #{short(info.started_at)}): `#{info.cmd}`. | <>
           "Read it with job_output, stop it with stop_job, or pick another name."}

      {:error, :bad_name} ->
        {:error,
         "a job name is letters, digits, . _ - (up to 64), starting with a letter or digit"}

      {:error, reason} ->
        {:error, "could not start the job: #{inspect(reason)}"}
    end
  end

  def jobs(_args, ctx) do
    case Longx.Jobs.list(ctx.thread_id || "") do
      [] -> {:ok, "No background jobs in this conversation."}
      jobs -> {:ok, Enum.map_join(jobs, "\n", &line/1)}
    end
  end

  def job_output(%{"name" => name} = args, ctx) do
    opts =
      [tail: positive(args["tail"]), grep: args["grep"]]
      |> Enum.reject(fn {_, v} -> v in [nil, ""] end)

    case Longx.Jobs.output(ctx.thread_id || "", name, opts) do
      {:ok, %{info: info, text: text, stats: stats}} ->
        cap = output_cap(args["max_output_tokens"])
        {clipped, _} = Shell.clip(text, cap)

        {:ok,
         state(info) <>
           "\n#{stats.lines} lines, #{stats.bytes} bytes written" <>
           if(stats.omitted_bytes > 0,
             do: " (#{stats.omitted_bytes} bytes from the middle not kept)",
             else: ""
           ) <> "\nOutput:\n" <> clipped}

      {:error, :unknown} ->
        unknown(name)
    end
  end

  def wait_job(%{"name" => name} = args, ctx) do
    timeout = min(positive(args["timeout_ms"]) || @wait_default, @wait_max)

    with {:ok, info} <- Longx.Jobs.wait(ctx.thread_id || "", name, timeout),
         {:ok, %{text: last}} <- Longx.Jobs.output(ctx.thread_id || "", name, tail: 20) do
      waited = if info.status == "running", do: " (waited #{timeout} ms)", else: ""
      {:ok, state(info) <> waited <> "\nLast lines:\n" <> last}
    else
      {:error, :unknown} -> unknown(name)
    end
  end

  def stop_job(%{"name" => name}, ctx) do
    case Longx.Jobs.stop(ctx.thread_id || "", name) do
      {:ok, %{status: "running"}} ->
        {:ok, ~s|Job "#{name}" is still ending.|}

      {:ok, %{status: "stopped"}} ->
        {:ok, ~s|Job "#{name}" stopped: its whole process tree ended.|}

      {:ok, info} ->
        {:ok, ~s|Job "#{name}" had already ended: | <> state(info)}

      {:error, :unknown} ->
        unknown(name)
    end
  end

  ## Words

  defp unknown(name),
    do: {:error, ~s|there is no job "#{name}" in this conversation; jobs lists them|}

  defp line(info) do
    ended = if info.finished_at, do: " → #{short(info.finished_at)}", else: ""
    "#{info.name}  #{status(info)}  #{short(info.started_at)}#{ended}  `#{info.cmd}`"
  end

  defp state(info) do
    case info.status do
      "running" ->
        ~s|Job "#{info.name}" is running (since #{short(info.started_at)}).|

      "exited" ->
        ~s|Job "#{info.name}" exited with code #{info.exit_code} (#{short(info.finished_at)}).|

      _ ->
        ~s|Job "#{info.name}" #{status(info)}.|
    end
  end

  defp status(%{status: "exited", exit_code: code}), do: "exited (code #{code})"
  defp status(%{status: "running"}), do: "running"
  defp status(%{status: status, reason: nil}), do: status
  defp status(%{status: status, reason: reason}), do: "#{status}: #{reason}"

  # "2026-09-24T05:08:38.811538Z" → "2026-09-24 05:08:38 UTC"
  defp short(nil), do: "?"

  defp short(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} ->
        dt |> DateTime.truncate(:second) |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")

      _ ->
        iso
    end
  end

  defp positive(n) when is_integer(n) and n > 0, do: n
  defp positive(n) when is_float(n) and n > 0, do: trunc(n)
  defp positive(_), do: nil

  defp output_cap(tokens) when is_number(tokens) and tokens > 0,
    do: trunc(tokens) * @bytes_per_token

  defp output_cap(_), do: @default_output_tokens * @bytes_per_token

  defp workdir(dir, ctx) when is_binary(dir) and dir != "", do: Context.path(ctx, dir)
  defp workdir(_dir, ctx), do: ctx.cwd || File.cwd!()
end
