defmodule Longx.ObanEngine do
  @moduledoc """
  SQLite's Lite engine with backpressure on a refused fetch.

  A busy UPDATE has not committed any jobs. Defer that fetch to Oban's
  next refresh/notification rather than crashing its one-for-all queue
  supervisor and killing workers already running. Disconnects and other
  errors are not safe to replay and still propagate.
  """
  @behaviour Oban.Engine
  require Logger
  alias Oban.Engines.Lite

  @impl true
  defdelegate init(conf, opts), to: Lite
  @impl true
  defdelegate put_meta(conf, meta, key, value), to: Lite
  @impl true
  defdelegate check_meta(conf, meta, running), to: Lite
  @impl true
  defdelegate refresh(conf, meta), to: Lite
  @impl true
  defdelegate shutdown(conf, meta), to: Lite
  @impl true
  defdelegate insert_job(conf, changeset, opts), to: Lite
  @impl true
  defdelegate insert_all_jobs(conf, changesets, opts), to: Lite
  @impl true
  defdelegate stage_jobs(conf, query, opts), to: Lite
  @impl true
  defdelegate prune_jobs(conf, query, opts), to: Lite
  @impl true
  defdelegate complete_job(conf, job), to: Lite
  @impl true
  defdelegate snooze_job(conf, job, seconds), to: Lite
  @impl true
  defdelegate discard_job(conf, job), to: Lite
  @impl true
  defdelegate error_job(conf, job, seconds), to: Lite
  @impl true
  defdelegate cancel_job(conf, job), to: Lite
  @impl true
  defdelegate cancel_all_jobs(conf, query), to: Lite
  @impl true
  defdelegate delete_job(conf, job), to: Lite
  @impl true
  defdelegate delete_all_jobs(conf, query), to: Lite
  @impl true
  defdelegate retry_job(conf, job), to: Lite
  @impl true
  defdelegate retry_all_jobs(conf, query), to: Lite
  @impl true
  defdelegate update_job(conf, job, changes), to: Lite

  @impl true
  def fetch_jobs(conf, meta, running) do
    Lite.fetch_jobs(conf, meta, running)
  rescue
    e in Exqlite.Error ->
      if Regex.match?(~r/\A(?:database busy|database is locked)(?:\z|\n)/i, e.message) do
        Logger.warning("oban: queue #{meta.queue} fetch deferred while SQLite is busy")
        {:ok, {meta, []}}
      else
        reraise e, __STACKTRACE__
      end
  end
end
