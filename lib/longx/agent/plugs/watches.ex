defmodule Longx.Agent.Plugs.Watches do
  @moduledoc """
  Watches for the agent (`Longx.Watches`): the file is written by the
  agent itself (`apply_patch` into `.longx/local/watches/<name>.exs`, a
  `Longx.Agent.Watch` module); the tools do what a file cannot —
  `watch_list` (the project's watches, reconciled now, with their state
  and load errors), `watch_run` (a dry run: what the script would send and
  log, without delivering), `watch_enable`, `wait_until` (the sugar for a
  loop: a once-only watch that sends the message back to this session at
  that time or cron, so the turn can end instead of sleeping) and `notify`
  (a line to the person's notification feed). The prompt teaches the file
  and says: never sleep in a turn — write a watch.
  """

  use Longx.Agent.Plug

  alias Longx.Projects
  alias Longx.Watches

  instructions """
  # Watches

  To have something checked on a schedule, to be woken by an outside event, or to come back to a task later — instead of sleeping or polling inside a turn — write a **watch**: a file `.longx/local/watches/<name>.exs` (a short lowercase name):

  ```elixir
  defmodule DeployHealth do
    use Longx.Agent.Watch
    every "*/5 * * * *"              # local time; or once "2026-09-19T08:00:00+08:00", or webhook true
    expires "2026-09-20T00:00:00+08:00"   # optional; or max_runs 24

    def run(ctx) do
      {code, out} = shell(ctx, "curl -fsS -m 5 http://localhost:8080/health")
      status = if code == 0, do: :ok, else: :fail
      if status != ctx.state[:status],
        do: send(ctx, "main", "health went from \#{ctx.state[:status]} to \#{status}:\\n\#{out}")
      {:ok, %{status: status}}       # next time, ctx.state is this
    end
  end
  ```

  It runs without you (no model call), in the project root as the person: `shell(ctx, cmd)` → `{exit_code, output}`, `http(ctx, url)`, `credential_request(ctx, name, url)`, `knowledge_read(ctx, path)`, `log(ctx, line)`; `send(ctx, to, text)` puts a message in a session's mailbox — `to` an address from the directory (your own handle to be told yourself) or `:self`, a session named after the watch that is started when there is none — delivered once that session is idle. Decide everything in the script (what changed, whom to tell); write the normal state you compare against into the knowledge. The file loads by itself (a broken one comes back as a ⚠ notice); **run `watch_run(name)` once after writing it** to see what it would do. Six sends per hour per watch. A once-only watch is consumed when it ran. **Where it lives**: `local/watches/` runs on this machine only (yours, not in git); a watch the team should have on every machine — the project's own health checks, its nightly jobs — goes to `.longx/shared/watches/<name>.exs` (in git; it runs where the project's trust switch is on; ask the person to promote a local one, or write it there when they asked for a shared one). To simply continue later, `wait_until(at | every, message)` writes such a file for you: call it, then end your turn saying when you will look again.
  """

  tool :watch_list,
       "The project's watches: schedule, switch, next and last run, what they last did, load errors." do
  end

  tool :watch_run,
       "Runs a watch's script now as a dry run: what it would log and send, its result — nothing is delivered." do
    param :name, :string, "The watch (its file name without .exs)", required: true
  end

  tool :watch_enable, "Switches a watch off (kept, not run) or on again." do
    param :name, :string, "The watch", required: true
    param :enabled, :boolean, "true on, false off", required: true
  end

  tool :wait_until,
       "Comes back to this session later with a message — writes a watch that sends it to you at that time (once) or on that cron (repeatedly). End your turn after calling it." do
    param :at,
          :string,
          "An instant, ISO 8601 (e.g. 2026-09-19T09:00:00+08:00; no offset = local time)"

    param :every, :string, "A five-field cron, local time (e.g. */30 * * * *) — instead of at"

    param :message,
          :string,
          "What to tell yourself then: the task, where things stand, what to check",
          required: true

    param :expires, :string, "For every: stop after this instant (default: 24 hours from now)"
  end

  tool :notify,
       "Pushes a line to the person's notification feed (their phone), about this session." do
    param :title, :string, "A short title", required: true
    param :body, :string, "One or two lines"
  end

  @impl true
  def call(%Step{phase: :request, project_id: project_id} = step, _opts)
      when is_binary(project_id),
      do: Longx.Agent.Plug.mount(step, __MODULE__)

  def call(step, _opts), do: step

  ## The tools

  def watch_list(_args, %{project_id: project_id}) when is_binary(project_id) do
    with {:ok, project} <- Ash.get(Projects.Project, project_id),
         :ok <- Watches.reconcile_project(project) do
      case Watches.list_for_project!(project_id) do
        [] ->
          {:ok, "no watch in this project yet (write one: .longx/local/watches/<name>.exs)"}

        rows ->
          {:ok, Enum.map_join(rows, "\n\n", &describe/1)}
      end
    else
      {:error, reason} -> {:error, "could not read the watches: #{inspect(reason)}"}
    end
  end

  def watch_list(_args, _ctx), do: {:error, "not inside a project"}

  def watch_run(%{"name" => name}, %{project_id: project_id}) when is_binary(project_id) do
    with {:ok, watch} <- find(project_id, name),
         {:ok, %{result: result, sends: sends, log: log}} <- Watches.dry_run(watch) do
      lines =
        Enum.map(log, &"log: #{&1}") ++
          Enum.map(sends, &"would send to #{inspect(&1.to)}: #{&1.text}") ++
          ["result: #{inspect(result)}"]

      {:ok, Enum.join(lines, "\n")}
    else
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, reason} -> {:error, "could not run #{name}: #{inspect(reason)}"}
    end
  end

  def watch_run(_args, _ctx), do: {:error, "not inside a project"}

  def watch_enable(%{"name" => name, "enabled" => enabled}, %{project_id: project_id})
      when is_binary(project_id) and is_boolean(enabled) do
    with {:ok, watch} <- find(project_id, name),
         {:ok, watch} <- Watches.set_switch(watch, enabled) do
      {:ok,
       if(watch.enabled,
         do: "#{name} is on; next run #{watch.next_due_at || "on its webhook"}",
         else: "#{name} is off (kept; watch_enable it again to resume)"
       )}
    else
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, reason} -> {:error, "could not switch #{name}: #{inspect(reason)}"}
    end
  end

  def watch_enable(_args, _ctx), do: {:error, "not inside a project"}

  def wait_until(%{"message" => message} = args, %{project_id: project_id, thread_id: thread_id})
      when is_binary(project_id) do
    with {:ok, schedule} <- schedule_of(args),
         {:ok, project} <- Ash.get(Projects.Project, project_id),
         {:ok, thread} <- Projects.get_thread_by_kernel_id(thread_id) do
      address = Projects.agent_name(thread)
      name = "wait-" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)
      module = "Wait" <> String.upcase(String.slice(name, -6, 6))
      dir = Path.join(project.root_path, ".longx/local/watches")
      File.mkdir_p!(dir)
      Longx.Agent.Definition.Layout.ensure_ignored(project.root_path)

      File.write!(Path.join(dir, name <> ".exs"), """
      defmodule #{module} do
        use Longx.Agent.Watch
        #{schedule}

        def run(ctx) do
          send(ctx, #{inspect(address)}, #{inspect(message)})
          {:ok, %{}}
        end
      end
      """)

      :ok = Watches.reconcile_project(project)

      case Watches.get_watch(project_id, name) do
        {:ok, %{enabled: true, next_due_at: next}} ->
          {:ok,
           "watch #{name} written: at #{next || args["every"]} the message comes back to you as a new turn — end your turn now, saying when you will look again"}

        {:ok, %{load_error: error}} ->
          {:error, "the watch could not load: #{error}"}

        {:error, reason} ->
          {:error, "the watch was not registered: #{inspect(reason)}"}
      end
    else
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, reason} -> {:error, "could not write the watch: #{inspect(reason)}"}
    end
  end

  def wait_until(_args, _ctx), do: {:error, "not inside a project"}

  def notify(%{"title" => title} = args, %{thread_id: thread_id}) when is_binary(thread_id) do
    case Projects.get_thread_by_kernel_id(thread_id) do
      {:ok, thread} ->
        :ok = Projects.notify(thread, "watch", title: title, body: args["body"] || title)
        {:ok, "notified"}

      {:error, _} ->
        {:error, "not inside a project"}
    end
  end

  def notify(_args, _ctx), do: {:error, "not inside a project"}

  ## helpers

  defp schedule_of(%{"at" => at}) when is_binary(at) and at != "",
    do: {:ok, ~s(once #{inspect(at)})}

  defp schedule_of(%{"every" => cron} = args) when is_binary(cron) and cron != "" do
    expires =
      args["expires"] ||
        DateTime.utc_now()
        |> DateTime.add(24 * 3600, :second)
        |> DateTime.truncate(:second)
        |> DateTime.to_iso8601()

    {:ok, ~s(every #{inspect(cron)}\n  expires #{inspect(expires)})}
  end

  defp schedule_of(_args), do: {:error, "give at (an instant) or every (a cron)"}

  defp find(project_id, name) do
    with {:ok, project} <- Ash.get(Projects.Project, project_id),
         :ok <- Watches.reconcile_project(project),
         {:ok, watch} <- Watches.get_watch(project_id, name) do
      {:ok, watch}
    else
      {:error, %Ash.Error.Invalid{}} ->
        {:error, "no watch named #{name}; watch_list names them"}

      {:error, %Ash.Error.Query.NotFound{}} ->
        {:error, "no watch named #{name}; watch_list names them"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp describe(%Watches.Watch{} = w) do
    schedule =
      case w.kind do
        :cron -> "every #{w.cron}"
        :once -> "once at #{w.at}"
        :webhook -> "webhook POST /hooks/#{w.webhook_token}"
      end

    state =
      cond do
        w.running_since ->
          "running since #{w.running_since}"

        not w.enabled ->
          "off (#{w.disabled_reason})" <> if(w.load_error, do: ": #{w.load_error}", else: "")

        true ->
          "on; next #{w.next_due_at || "on its trigger"}"
      end

    last =
      if w.last_run_at,
        do:
          "last run #{w.last_run_at} (#{w.last_duration_ms} ms)" <>
            if(w.last_error, do: " error: #{w.last_error}", else: "") <>
            if(w.last_output && w.last_output != "",
              do: "\n  #{String.replace(w.last_output, "\n", "\n  ")}",
              else: ""
            ),
        else: "never ran"

    "#{w.name} (#{w.layer}) — #{schedule}; #{state}; runs #{w.runs}, sends #{w.sends}; state #{inspect(w.state)}\n  #{last}"
  end
end
