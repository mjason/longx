defmodule Longx.Watches.Tick do
  @moduledoc """
  The clock: Oban's cron runs this every minute (`config :longx, Oban`).
  It reconciles every active project's watch files into rows and queues
  one `Longx.Watches.Runner` job per watch that is due — unique per watch,
  so a slow run is never doubled.
  """

  use Oban.Worker, queue: :watches, max_attempts: 1

  alias Longx.Watches

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Watches.reconcile()

    DateTime.utc_now()
    |> Watches.due!()
    |> Enum.map(&Watches.Runner.new(%{"id" => &1.id}))
    |> Oban.insert_all()

    :ok
  end
end
