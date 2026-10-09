defmodule Longx.Jobs.Job do
  @moduledoc """
  One background job: a process of Longx's own (`:temporary` under
  `Longx.Jobs.Supervisor`, `{thread_id, name}` in `Longx.Jobs.Registry`) that
  holds the command's shim, so the job outlives the tool call that started
  it, the turn, and the agent leaving idle. Its output goes to a bounded
  `Longx.Jobs.Log`; it is in the command ledger (`Longx.System.Pressure` —
  the settings page lists and stops it, the memory watchdog guards it).

  When the command ends — by itself, stopped by the agent (`stop_job`), by
  the person from the settings page, or by the memory watchdog — the job
  writes its end into `job.json`, answers whoever waits, and, unless the
  agent already saw the end, tells the agent (`on_exit`). Then it stops;
  a finished job reads back from its directory.
  """

  use GenServer, restart: :temporary

  alias Longx.Jobs
  alias Longx.Jobs.Log
  alias Longx.Shim
  alias Longx.Shim.ResourceReport

  @registry Longx.Jobs.Registry

  def start_link(spec),
    do: GenServer.start_link(__MODULE__, spec, name: via(spec.thread_id, spec.name))

  def via(thread_id, name), do: {:via, Registry, {@registry, {thread_id, name}}}

  @impl true
  def init(spec) do
    mode = spec.guards[:cgroup] || spec.guards[:command_cgroup_mode] || :off

    case Longx.System.CommandGuard.start_check(mode) do
      :ok -> start(spec, mode)
      {:error, reason} -> {:stop, {:could_not_start, reason}}
    end
  end

  defp start(spec, mode) do
    Process.flag(:trap_exit, true)
    log = Log.open(Path.join(spec.dir, "log"), spec.log_opts)

    info = %{
      name: spec.name,
      cmd: spec.cmd,
      cwd: spec.cwd,
      status: "running",
      exit_code: nil,
      reason: nil,
      run: spec.run,
      notify: spec.notify,
      purpose: spec.purpose,
      review: nil,
      review_note: nil,
      observed: false,
      started_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      finished_at: nil
    }

    shim_opts =
      [cd: spec.cwd, env: spec.env, env_clear: true, stderr: :redirect_to_stdout, stdin: :null] ++
        Enum.filter(spec.guards, fn {k, v} ->
          k in [:oom_score_adj, :cgroup, :memory_max, :swap_max, :cgroup_root] and v != nil
        end)

    case Shim.start_link([spec.shell, spec.flag, spec.cmd], shim_opts) do
      {:ok, shim} ->
        warning =
          ResourceReport.warning(Shim.resource_guard(shim)) ||
            Longx.System.CommandGuard.unsupported_warning(mode)

        log = if warning, do: Log.write(log, warning <> "\n"), else: log
        info = %{info | reason: warning}

        :ok =
          Longx.System.Pressure.register(%{
            id: "job_" <> spec.run,
            shim: shim,
            os_pid: Shim.os_pid(shim),
            floor: spec.guards[:floor] || 0,
            cmd: "[job #{spec.name}] #{spec.cmd}",
            thread_id: spec.thread_id,
            started_at: System.system_time(:millisecond)
          })

        me = self()
        spawn_link(fn -> pump(shim, me) end)

        spawn_link(fn ->
          result = Shim.await_exit(shim, :infinity, close_streams: false)
          send(me, {:exited, result, Shim.resource_exit(shim)})
        end)

        Jobs.save_info(spec.dir, info)

        {:ok,
         %{
           spec: spec,
           shim: shim,
           log: log,
           info: info,
           eof?: false,
           exit: nil,
           ending: nil,
           resource_exit: nil,
           guard_warning: warning,
           waiters: [],
           person_stop?: false,
           began: System.monotonic_time(:millisecond)
         }}

      {:error, reason} ->
        Log.close(log)
        {:stop, {:could_not_start, reason}}
    end
  end

  defp pump(shim, owner) do
    case Shim.read(shim, 65_536, :infinity) do
      {:ok, data} ->
        send(owner, {:out, data})
        pump(shim, owner)

      _eof_or_error ->
        send(owner, :eof)
    end
  end

  ## Calls

  @impl true
  def handle_call(:info, _from, state), do: {:reply, state.info, state}

  def handle_call({:update_info, run, fun}, _from, state) do
    if state.info.run == run do
      case fun.(state.info) do
        {:error, _} = error ->
          {:reply, error, state}

        info ->
          Jobs.save_info(state.spec.dir, info)
          {:reply, {:ok, info}, %{state | info: info}}
      end
    else
      {:reply, {:error, :stale_run}, state}
    end
  end

  def handle_call({:output, opts}, _from, state),
    do:
      {:reply,
       %{info: state.info, text: Log.render(state.log, opts), stats: Log.stats(state.log)}, state}

  def handle_call({:wait, timeout}, from, state) do
    ref = make_ref()
    Process.send_after(self(), {:wait_timeout, ref}, timeout)
    {:noreply, %{state | waiters: [{ref, from} | state.waiters]}}
  end

  # the agent stops it: it knows how it ended
  def handle_call({:stop, run, by}, from, state) do
    if run && run != state.info.run do
      {:reply, {:error, :stale_run}, state}
    else
      reason =
        if by == :person,
          do: "stopped by the person; the work is incomplete — do not restart it unless asked",
          else: "stopped by the agent (stop_job)"

      state = ending(state, "stopped", reason, observed: by != :person)
      ref = make_ref()
      {:noreply, %{state | waiters: [{ref, from} | state.waiters], person_stop?: by == :person}}
    end
  end

  @impl true
  def handle_info({:out, data}, state), do: {:noreply, %{state | log: Log.write(state.log, data)}}

  def handle_info(:eof, state), do: maybe_finish(%{state | eof?: true})

  def handle_info({:exited, result}, state) do
    code = with {:ok, code} <- result, do: code, else: (_ -> -1)
    maybe_finish(%{state | exit: code})
  end

  def handle_info({:exited, result, resource}, state) do
    code = with {:ok, code} <- result, do: code, else: (_ -> -1)
    maybe_finish(%{state | exit: code, resource_exit: resource})
  end

  def handle_info({:kill_command, _by}, state) do
    {:noreply,
     ending(
       state,
       "killed",
       "stopped from the settings page by the person; do not start it again as it was — ask what to do next"
     )}
  end

  def handle_info({:memory_pressure, %{percent: percent}}, state) do
    {:noreply,
     ending(
       state,
       "killed",
       "killed by Longx: the machine was down to #{percent}% free memory; run a smaller job and check its memory before going bigger"
     )}
  end

  def handle_info({:wait_timeout, ref}, state) do
    case List.keytake(state.waiters, ref, 0) do
      {{^ref, from}, rest} ->
        GenServer.reply(from, {:ok, state.info})
        {:noreply, %{state | waiters: rest}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{shim: shim}) do
    Shim.kill(shim)
  catch
    _, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

  ## The end

  # a stop asked for: the tree is ended; the exit that follows is written with this
  defp ending(state, status, reason, opts \\ [])

  defp ending(%{ending: nil} = state, status, reason, opts) do
    Shim.kill(state.shim)
    %{state | ending: {status, reason, Keyword.get(opts, :observed, false)}}
  end

  defp ending(state, _status, _reason, _opts), do: state

  defp maybe_finish(%{eof?: true, exit: code} = state) when is_integer(code) do
    resource_reason = ResourceReport.exit_reason(state.resource_exit)

    {status, reason, observed} =
      ResourceReport.job_end(state.ending, state.guard_warning, state.resource_exit)

    log = if resource_reason, do: Log.write(state.log, resource_reason <> "\n"), else: state.log

    duration = System.monotonic_time(:millisecond) - state.began
    Log.close(log)

    info = %{
      state.info
      | status: status,
        exit_code: code,
        reason: reason,
        observed: observed,
        finished_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    # (its ledger entry goes with this process, a moment from now)
    Jobs.save_info(state.spec.dir, info)

    # the waiters see the end: that is the agent seeing it
    info =
      if state.waiters != [] and not state.person_stop?,
        do: mark_observed(state.spec.dir, info),
        else: info

    for {_ref, from} <- state.waiters, do: GenServer.reply(from, {:ok, info})

    if info.notify and not info.observed do
      notice = %{
        name: info.name,
        run: info.run,
        cmd: info.cmd,
        status: status,
        exit_code: code,
        reason: reason,
        duration_ms: duration,
        tail: Log.read(Path.join(state.spec.dir, "log"), tail: 20)
      }

      on_exit = state.spec.on_exit
      Task.start(fn -> on_exit.(notice) end)
    end

    Phoenix.PubSub.broadcast(Longx.PubSub, Jobs.topic(state.spec.thread_id), {:job, info})
    {:stop, :normal, %{state | info: info, shim: nil}}
  end

  defp maybe_finish(state), do: {:noreply, state}

  defp mark_observed(dir, info) do
    info = %{info | observed: true}
    Jobs.save_info(dir, info)
    info
  end
end
