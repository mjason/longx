defmodule Longx.Watches do
  @moduledoc """
  Watches — scripts the agent (or the person) writes under
  `.longx/local/watches/` (or `shared/watches/`, behind the trust switch)
  that Oban runs on a schedule and that speak to sessions through their
  mailboxes (`docs/watches-design.md`).

  A watch file is a module `use`ing `Longx.Agent.Watch`: its head says
  when (`every` cron / `once` instant / `webhook`), its `run/1` does the
  rest — checks whatever it likes with `shell`, `http`,
  `credential_request`, `knowledge_read`, decides, and `send`s to a
  session by address or to `:self`, the session named after it. The
  runtime keeps no policy. Files are the definition,
  `Longx.Watches.Watch` rows are the state (`reconcile_project/1` keeps
  them in step: a new file is a row, a changed file a resynced row, a gone
  file a gone row, a broken file a disabled row and a notice in front of
  the agent).

  The clock is Oban: `Longx.Watches.Tick` every minute (reconcile, queue
  a `Runner` per due row), `Longx.Watches.Runner` one run (`run/2`): the
  script in a task under `Longx.Watches.TaskSupervisor` for at most its
  `timeout`, its sends through `Longx.Projects.deliver/4` (`deliver:
  :idle` — never a steer) with a budget per hour, the outcome on the row
  (`state`, `last_*`, counts, `next_due_at`), a once-only file consumed. A
  webhook watch runs when `POST /hooks/<token>` arrives. What happens is
  told: `Longx.Notify` (kind `watch`) for a budget stop, a broken file,
  and the project channel's `"watches"` push whenever a row changes, so
  the settings page sees what runs.
  """

  use Ash.Domain, otp_app: :longx, extensions: [AshTypescript.Rpc]

  require Logger

  alias Longx.Agent.Definition.Loader
  alias Longx.Projects
  alias Longx.Projects.Project
  alias Longx.Watches.Watch

  @task_supervisor Longx.Watches.TaskSupervisor
  @output_bytes 2_048

  typescript_rpc do
    resource Watch do
      rpc_action :list_watches, :for_project
      rpc_action :switch_watch, :switch
      rpc_action :dry_run_watch, :dry_run
      rpc_action :delete_watch, :delete_watch
      rpc_action :list_all_watches, :list_all
    end
  end

  resources do
    resource Watch do
      define :create_watch, action: :create
      define :sync_watch, action: :sync
      define :begin_run, action: :begin_run
      define :finish_run, action: :finish_run
      define :count_send, action: :count_send
      define :set_enabled, action: :set_enabled, args: [:enabled, :disabled_reason]
      define :put_state, action: :set_state, args: [:state]
      define :put_due, action: :set_due, args: [:next_due_at]
      define :list_for_project, action: :for_project, args: [:project_id]
      define :get_watch, action: :by_name, args: [:project_id, :name]
      define :get_by_token, action: :by_token, args: [:token]
      define :due, action: :due, args: [:now]
      define :list_running, action: :running
    end
  end

  ## Files → rows

  @doc "Every active project's watch files reconciled into rows."
  @spec reconcile() :: :ok
  def reconcile do
    for %Project{} = project <- Projects.list_active_projects!() do
      case reconcile_project(project) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("watches: #{project.name}: #{inspect(reason)}")
      end
    end

    :ok
  end

  @doc """
  The project's watch files (through the definition loader — cached by
  mtime, the shared tree only when trusted) reconciled into its rows.
  """
  @spec reconcile_project(Project.t()) :: :ok | {:error, term}
  def reconcile_project(%Project{id: id, root_path: root} = project) do
    loaded = Loader.load(root, tag: id, trusted: project.trust_local_agent)
    rows = id |> list_for_project!() |> Map.new(&{&1.name, &1})
    now = DateTime.utc_now()

    good = Map.new(loaded.watches, &{&1.name, &1})

    broken =
      for %{file: file, message: message} <- loaded.errors,
          is_binary(file) and String.contains?(file, "/watches/") and
            String.ends_with?(file, ".exs"),
          into: %{},
          do: {Path.basename(file, ".exs"), %{path: file, message: message}}

    with :ok <- upsert_good(id, good, rows, now),
         :ok <- upsert_broken(id, broken, rows),
         :ok <- drop_gone(rows, Map.keys(good) ++ Map.keys(broken)) do
      if map_size(good) + map_size(broken) + map_size(rows) > 0, do: broadcast(id)
      :ok
    end
  end

  defp upsert_good(project_id, good, rows, now) do
    Enum.reduce_while(good, :ok, fn {name, watch}, :ok ->
      attrs = definition_attrs(watch, now)

      result =
        case Map.get(rows, name) do
          nil ->
            create_watch(Map.merge(attrs, %{project_id: project_id, name: name, enabled: true}))

          %Watch{} = row ->
            sync_watch(row, resync_attrs(row, attrs))
        end

      case result do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # a row whose schedule did not change keeps its next time and its switch;
  # one that was off for a bad file comes back on; a changed schedule is rescheduled
  defp resync_attrs(%Watch{} = row, attrs) do
    same_schedule? =
      row.kind == attrs.kind and row.cron == attrs.cron and
        DateTime.compare(row.at || DateTime.from_unix!(0), attrs.at || DateTime.from_unix!(0)) ==
          :eq

    base =
      Map.merge(attrs, %{load_error: nil, webhook_token: row.webhook_token || attrs.webhook_token})

    base =
      if same_schedule? and row.next_due_at != nil and row.enabled,
        do: Map.put(base, :next_due_at, row.next_due_at),
        else: base

    if row.disabled_reason == :load_error,
      do: Map.merge(base, %{enabled: true, disabled_reason: nil}),
      else: Map.merge(base, %{enabled: row.enabled, disabled_reason: row.disabled_reason})
  end

  defp upsert_broken(project_id, broken, rows) do
    Enum.reduce_while(broken, :ok, fn {name, %{path: path, message: message}}, :ok ->
      attrs = %{
        path: path,
        layer: layer_of(path),
        enabled: false,
        disabled_reason: :load_error,
        load_error: String.slice(message, 0, 1_000)
      }

      result =
        case Map.get(rows, name) do
          nil ->
            create_watch(Map.merge(attrs, %{project_id: project_id, name: name, kind: :cron}))

          %Watch{load_error: ^message} ->
            {:ok, :same}

          %Watch{} = row ->
            notify_project(project_id, "watch #{name} 无法加载", message)
            sync_watch(row, attrs)
        end

      case result do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp drop_gone(rows, present) do
    for {name, row} <- rows, name not in present, do: Ash.destroy!(row)
    :ok
  end

  defp definition_attrs(%{definition: d, path: path, layer: layer}, now) do
    %{
      path: path,
      layer: layer,
      kind: d.kind,
      cron: d.cron,
      at: d.at,
      expires_at: d.expires_at,
      max_runs: d.max_runs,
      timeout_ms: d.timeout,
      budget_per_hour: d.budget,
      next_due_at: first_due(d, now),
      webhook_token: if(d.kind == :webhook, do: token(), else: nil)
    }
  end

  # a once instant already past is due now (the file was written for it)
  defp first_due(%{kind: :once, at: at}, _now), do: at
  defp first_due(d, now), do: Longx.Agent.Watch.next_due_at(d, now)

  defp layer_of(path), do: if(String.contains?(path, "/shared/"), do: :project, else: :local)

  defp token, do: 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  ## A run

  @doc """
  Runs the watch now: its file loaded again (a broken one disables the
  row), the script in a task for at most its timeout, the sends delivered
  (`payload:` a webhook's body), the outcome on the row. `{:ok, row}` with
  what happened on it; `{:error, reason}` only when the row or the project
  is gone.
  """
  @spec run(Watch.t(), keyword) :: {:ok, Watch.t()} | {:error, term}
  def run(%Watch{} = watch, opts \\ []) do
    with {:ok, %Project{} = project} <- Ash.get(Project, watch.project_id),
         {:ok, watch} <- Ash.get(Watch, watch.id) do
      case definition_of(project, watch) do
        {:ok, loaded} -> run_loaded(project, watch, loaded, opts)
        {:error, message} -> disable(watch, :load_error, message)
      end
    end
  end

  defp definition_of(%Project{id: id, root_path: root} = project, %Watch{name: name}) do
    loaded = Loader.load(root, tag: id, trusted: project.trust_local_agent)

    case Enum.find(loaded.watches, &(&1.name == name)) do
      nil ->
        message =
          Enum.find_value(loaded.errors, "the file is gone or does not load", fn
            %{file: file, message: message} ->
              if is_binary(file) and Path.basename(file, ".exs") == name, do: message
          end)

        {:error, message}

      watch ->
        {:ok, watch}
    end
  end

  defp run_loaded(project, %Watch{} = watch, loaded, opts) do
    if over?(watch, loaded.definition) do
      disable(watch, :expired, nil)
    else
      started = System.monotonic_time(:millisecond)
      {:ok, watch} = begin_run(watch, %{running_since: DateTime.utc_now()})
      broadcast(project.id)

      ctx = %{
        name: watch.name,
        project_root: project.root_path,
        state: watch.state,
        payload: Keyword.get(opts, :payload),
        deliver: deliver_fun(project, watch)
      }

      outcome = run_script(loaded.module, ctx, loaded.definition.timeout)
      finish(project, watch, loaded, outcome, System.monotonic_time(:millisecond) - started)
    end
  end

  defp over?(%Watch{} = watch, definition) do
    now = DateTime.utc_now()

    (definition.expires_at != nil and DateTime.compare(definition.expires_at, now) != :gt) or
      (definition.max_runs != nil and watch.runs >= definition.max_runs)
  end

  defp run_script(module, ctx, timeout) do
    task =
      Task.Supervisor.async_nolink(@task_supervisor, fn ->
        Longx.Agent.Watch.run(module, ctx)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, outcome} ->
        outcome

      {:exit, reason} ->
        %{result: {:error, "the run crashed: #{inspect(reason)}"}, sends: [], log: []}

      nil ->
        %{result: {:error, "the run did not finish within #{timeout} ms"}, sends: [], log: []}
    end
  end

  # what the script's `send` does: the hour's budget, then the mailbox
  defp deliver_fun(%Project{} = project, %Watch{id: id, name: name}) do
    from = "watch-" <> name

    fn to, text, opts ->
      with {:ok, watch} <- Ash.get(Watch, id),
           {:ok, watch} <- within_budget(watch),
           {:ok, address} <- address_of(project, to, name),
           {:ok, _thread} <-
             Projects.deliver(project.id, address, text,
               from: from,
               deliver: Keyword.get(opts, :deliver, :idle)
             ) do
        {:ok, _} =
          count_send(watch, %{
            sends: watch.sends + 1,
            sends_this_hour: watch.sends_this_hour + 1,
            hour_started_at: watch.hour_started_at,
            last_sent_to: address
          })

        Projects.notify_project(project.id, "watch",
          title: "watch #{name} 叫醒了 #{address}",
          body: String.slice(text, 0, 200)
        )

        :ok
      else
        {:error, :budget} = error ->
          _ = disable(Ash.get!(Watch, id), :budget, nil)
          error

        {:error, _} = error ->
          error
      end
    end
  end

  # the hour's window rolls with the first send; at the budget the row is off
  defp within_budget(%Watch{} = watch) do
    now = DateTime.utc_now()

    watch =
      if watch.hour_started_at == nil or
           DateTime.diff(now, watch.hour_started_at, :second) >= 3_600,
         do: %{watch | sends_this_hour: 0, hour_started_at: now},
         else: watch

    if watch.sends_this_hour >= watch.budget_per_hour, do: {:error, :budget}, else: {:ok, watch}
  end

  defp address_of(%Project{} = project, :self, name) do
    handle = "watch-" <> name

    with {:ok, %{handle: ^handle}} <- Projects.session_named(project, handle, title: "⏰ " <> name),
         do: {:ok, handle}
  end

  defp address_of(_project, to, _name) when is_binary(to), do: {:ok, to}
  defp address_of(_project, to, _name), do: {:error, {:bad_address, to}}

  defp finish(project, %Watch{} = watch, loaded, outcome, duration_ms) do
    # the row as the run left it (the sends counted, a budget stop applied)
    {:ok, fresh} = Ash.get(Watch, watch.id)
    now = DateTime.utc_now()
    %{result: result, sends: sends, log: log} = outcome
    definition = loaded.definition

    {state, error} =
      case result do
        {:ok, state} -> {state, nil}
        {:error, message} -> {fresh.state, message}
      end

    if error, do: Longx.System.Faults.record(:watch, watch.name, error)

    output =
      (log ++ Enum.map(sends, &"→ #{inspect(&1.to)}: #{String.slice(&1.text, 0, 200)}"))
      |> Enum.join("\n")
      |> String.slice(0, @output_bytes)

    runs = fresh.runs + 1

    {enabled, reason, next} =
      cond do
        not fresh.enabled ->
          {false, fresh.disabled_reason, nil}

        definition.kind == :once ->
          consume_file(loaded.path)
          {false, :done, nil}

        definition.max_runs != nil and runs >= definition.max_runs ->
          {false, :expired, nil}

        true ->
          {true, nil, Longx.Agent.Watch.next_due_at(definition, now)}
      end

    result =
      finish_run(fresh, %{
        state: state,
        last_run_at: now,
        last_duration_ms: duration_ms,
        last_error: error && String.slice(error, 0, 1_000),
        last_output: output,
        last_sent_to: fresh.last_sent_to,
        runs: runs,
        sends: fresh.sends,
        sends_this_hour: fresh.sends_this_hour,
        hour_started_at: fresh.hour_started_at,
        next_due_at: next,
        running_since: nil,
        enabled: enabled,
        disabled_reason: reason
      })

    broadcast(project.id)
    result
  end

  # a once-only watch is consumed with its file (the row goes at the next reconcile)
  defp consume_file(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("watches: could not remove #{path}: #{inspect(reason)}")
    end
  end

  defp disable(%Watch{} = watch, reason, message) do
    with {:ok, watch} <-
           finish_run(watch, %{
             running_since: nil,
             enabled: false,
             disabled_reason: reason,
             last_error: message && String.slice(message, 0, 1_000),
             next_due_at: nil
           }) do
      title =
        case reason do
          :budget -> "watch #{watch.name} 已暂停：一小时内叫醒次数用完"
          :load_error -> "watch #{watch.name} 无法加载"
          :expired -> "watch #{watch.name} 已结束"
        end

      if reason in [:budget, :load_error],
        do: notify_project(watch.project_id, title, message || "")

      broadcast(watch.project_id)
      {:ok, watch}
    end
  end

  defp notify_project(project_id, title, body),
    do: Projects.notify_project(project_id, "watch", title: title, body: body)

  ## Dry runs, the person's switches, boot

  @doc "Runs the script now without delivering: what it would send and log, its result."
  @spec dry_run(Watch.t()) :: {:ok, map} | {:error, term}
  def dry_run(%Watch{} = watch) do
    with {:ok, %Project{} = project} <- Ash.get(Project, watch.project_id),
         {:ok, loaded} <- definition_of(project, watch) do
      ctx = %{
        name: watch.name,
        project_root: project.root_path,
        state: watch.state,
        payload: nil,
        deliver: :dry
      }

      {:ok, run_script(loaded.module, ctx, loaded.definition.timeout)}
    end
  end

  @doc "The person's switch: off with `:by_person`, on again with the next time computed."
  @spec set_switch(Watch.t(), boolean) :: {:ok, Watch.t()} | {:error, term}
  def set_switch(%Watch{} = watch, false) do
    with {:ok, watch} <- set_enabled(watch, false, :by_person) do
      broadcast(watch.project_id)
      {:ok, watch}
    end
  end

  def set_switch(%Watch{} = watch, true) do
    with {:ok, %Project{} = project} <- Ash.get(Project, watch.project_id),
         {:ok, loaded} <- definition_of(project, watch),
         {:ok, watch} <- set_enabled(watch, true, nil),
         {:ok, watch} <- put_due(watch, first_due(loaded.definition, DateTime.utc_now())) do
      broadcast(watch.project_id)
      {:ok, watch}
    end
  end

  @doc "Deletes the watch: its file (the definition), then its row."
  @spec delete(Watch.t()) :: :ok | {:error, term}
  def delete(%Watch{path: path} = watch) do
    case File.rm(path) do
      ok when ok == :ok or ok == {:error, :enoent} ->
        Ash.destroy!(watch)
        broadcast(watch.project_id)
        :ok

      {:error, reason} ->
        {:error, "could not remove #{path}: #{inspect(reason)}"}
    end
  end

  @doc """
  Every project's watches for the global page, running ones first, each
  with its project's name and slug — plain maps, camelCased for the wire.
  """
  @spec overview() :: [map]
  def overview do
    projects = Map.new(Projects.list_all_projects!(), &{&1.id, &1})

    Watch
    |> Ash.read!()
    |> Enum.map(fn %Watch{} = w ->
      project = projects[w.project_id]

      w
      |> Map.take([
        :id,
        :project_id,
        :name,
        :kind,
        :cron,
        :at,
        :enabled,
        :disabled_reason,
        :running_since,
        :next_due_at,
        :last_run_at,
        :last_duration_ms,
        :last_error,
        :last_sent_to,
        :runs,
        :sends
      ])
      |> Map.merge(%{
        project_name: project && project.name,
        project_slug: project && project.slug
      })
      |> Map.new(fn {key, value} -> {camel(key), wire(value)} end)
    end)
    |> Enum.sort_by(fn row ->
      {if(row["runningSince"], do: 0, else: 1), row["nextDueAt"] || "~", row["name"]}
    end)
  end

  defp camel(key) do
    <<first, rest::binary>> = key |> Atom.to_string() |> Macro.camelize()
    <<String.downcase(<<first>>)::binary, rest::binary>>
  end

  defp wire(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp wire(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp wire(value), do: value

  @doc false
  def mark_running(%Watch{} = watch), do: begin_run(watch, %{running_since: DateTime.utc_now()})

  @doc "A boot: a run a previous BEAM left marked running is not running."
  @spec settle_after_restart() :: :ok
  def settle_after_restart do
    for %Watch{} = watch <- list_running!() do
      finish_run(watch, %{running_since: nil, last_error: "interrupted by a restart"})
    end

    :ok
  end

  @doc "The project channel hears that the watches changed (`\"watches\"`)."
  @spec broadcast(String.t()) :: :ok
  def broadcast(project_id) do
    Phoenix.PubSub.broadcast(
      Longx.PubSub,
      Projects.topic(project_id),
      {:watches_changed, project_id}
    )
  end
end
