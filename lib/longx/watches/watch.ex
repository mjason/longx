defmodule Longx.Watches.Watch do
  @moduledoc """
  The runtime row of a watch: the file (`.longx/…/watches/<name>.exs`,
  `Longx.Agent.Watch`) is the definition, this row is its state — when it
  is due, what its last run returned and said, whether it is running now,
  how many times it ran and sent, and why it is off. Keyed by project and
  name; `Longx.Watches.reconcile_project/1` keeps rows and files in step.
  """

  use Ash.Resource,
    otp_app: :longx,
    domain: Longx.Watches,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshTypescript.Resource]

  sqlite do
    table "watches"
    repo Longx.Repo
  end

  typescript do
    type_name "Watch"
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :project_id,
        :name,
        :path,
        :layer,
        :kind,
        :cron,
        :at,
        :expires_at,
        :max_runs,
        :timeout_ms,
        :budget_per_hour,
        :next_due_at,
        :enabled,
        :disabled_reason,
        :load_error,
        :webhook_token
      ]
    end

    # the file changed (or loaded again): the definition columns follow it
    update :sync do
      accept [
        :path,
        :layer,
        :kind,
        :cron,
        :at,
        :expires_at,
        :max_runs,
        :timeout_ms,
        :budget_per_hour,
        :next_due_at,
        :enabled,
        :disabled_reason,
        :load_error,
        :webhook_token
      ]
    end

    update :begin_run do
      accept [:running_since]
    end

    update :finish_run do
      accept [
        :state,
        :last_run_at,
        :last_duration_ms,
        :last_error,
        :last_output,
        :last_sent_to,
        :runs,
        :sends,
        :sends_this_hour,
        :hour_started_at,
        :next_due_at,
        :running_since,
        :enabled,
        :disabled_reason
      ]
    end

    update :count_send do
      accept [:sends, :sends_this_hour, :hour_started_at, :last_sent_to]
    end

    update :set_enabled do
      accept [:enabled, :disabled_reason]
    end

    update :set_state do
      accept [:state]
    end

    update :set_due do
      accept [:next_due_at]
    end

    read :for_project do
      argument :project_id, :uuid, allow_nil?: false
      filter expr(project_id == ^arg(:project_id))
      prepare build(sort: [name: :asc])
    end

    read :by_name do
      argument :project_id, :uuid, allow_nil?: false
      argument :name, :string, allow_nil?: false
      get? true
      filter expr(project_id == ^arg(:project_id) and name == ^arg(:name))
    end

    read :by_token do
      argument :token, :string, allow_nil?: false
      get? true
      filter expr(webhook_token == ^arg(:token))
    end

    # what the tick runs: enabled, on a clock, due, not running
    read :due do
      argument :now, :utc_datetime_usec, allow_nil?: false

      filter expr(
               enabled and kind in [:cron, :once] and not is_nil(next_due_at) and
                 next_due_at <= ^arg(:now) and is_nil(running_since)
             )
    end

    read :running do
      filter expr(not is_nil(running_since))
    end

    ## For the pages (the work is in Longx.Watches)

    # the person's switch: off keeps the watch, on schedules it again
    action :switch, :struct do
      constraints instance_of: __MODULE__
      argument :id, :uuid, allow_nil?: false
      argument :enabled, :boolean, allow_nil?: false

      run fn input, _ ->
        with {:ok, watch} <- Ash.get(__MODULE__, input.arguments.id),
             do: Longx.Watches.set_switch(watch, input.arguments.enabled)
      end
    end

    # a dry run: what the script would log and send, its result
    action :dry_run, :map do
      constraints fields: [
                    ok: [type: :boolean, allow_nil?: false],
                    result: [type: :string, allow_nil?: false],
                    log: [type: {:array, :string}, allow_nil?: false],
                    sends: [type: {:array, :string}, allow_nil?: false]
                  ]

      argument :id, :uuid, allow_nil?: false

      run fn input, _ ->
        with {:ok, watch} <- Ash.get(__MODULE__, input.arguments.id) do
          case Longx.Watches.dry_run(watch) do
            {:ok, %{result: result, log: log, sends: sends}} ->
              {:ok,
               %{
                 ok: match?({:ok, _}, result),
                 result: inspect(result, limit: 50, printable_limit: 2_000),
                 log: log,
                 sends: Enum.map(sends, &"#{inspect(&1.to)}: #{&1.text}")
               }}

            # the file does not load: that is the result of the try
            {:error, message} when is_binary(message) ->
              {:ok, %{ok: false, result: message, log: [], sends: []}}

            {:error, reason} ->
              {:ok, %{ok: false, result: inspect(reason), log: [], sends: []}}
          end
        end
      end
    end

    # the file goes, and with it the row
    action :delete_watch, :boolean do
      argument :id, :uuid, allow_nil?: false

      run fn input, _ ->
        with {:ok, watch} <- Ash.get(__MODULE__, input.arguments.id),
             :ok <- Longx.Watches.delete(watch),
             do: {:ok, true}
      end
    end

    # every project's watches, the running ones first (the global settings page)
    action :list_all, :map do
      constraints fields: [watches: [type: {:array, :map}, allow_nil?: false]]

      run fn _input, _ ->
        {:ok, %{watches: Longx.Watches.overview()}}
      end
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string, allow_nil?: false, public?: true
    attribute :path, :string, allow_nil?: false, public?: true

    attribute :layer, :atom do
      allow_nil? false
      public? true
      default :local
      constraints one_of: [:local, :project]
    end

    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:cron, :once, :webhook]
    end

    attribute :cron, :string, public?: true
    attribute :at, :utc_datetime_usec, public?: true
    attribute :expires_at, :utc_datetime_usec, public?: true
    attribute :max_runs, :integer, public?: true
    attribute :timeout_ms, :integer, allow_nil?: false, default: 30_000, public?: true
    attribute :budget_per_hour, :integer, allow_nil?: false, default: 6, public?: true

    # the scheduler reads this column and nothing else
    attribute :next_due_at, :utc_datetime_usec, public?: true

    # what the last run returned: the next run's ctx.state
    attribute :state, :map, allow_nil?: false, default: %{}, public?: true

    attribute :running_since, :utc_datetime_usec, public?: true
    attribute :last_run_at, :utc_datetime_usec, public?: true
    attribute :last_duration_ms, :integer, public?: true
    attribute :last_error, :string, public?: true
    attribute :last_output, :string, public?: true
    attribute :last_sent_to, :string, public?: true

    attribute :runs, :integer, allow_nil?: false, default: 0, public?: true
    attribute :sends, :integer, allow_nil?: false, default: 0, public?: true
    attribute :sends_this_hour, :integer, allow_nil?: false, default: 0, public?: true
    attribute :hour_started_at, :utc_datetime_usec, public?: true

    attribute :enabled, :boolean, allow_nil?: false, default: true, public?: true

    attribute :disabled_reason, :atom do
      public? true
      constraints one_of: [:by_person, :load_error, :budget, :expired, :done]
    end

    attribute :load_error, :string, public?: true
    attribute :webhook_token, :string, public?: true

    timestamps public?: true
  end

  relationships do
    belongs_to :project, Longx.Projects.Project, allow_nil?: false, public?: true
  end

  identities do
    identity :unique_name_in_project, [:project_id, :name]
  end
end
