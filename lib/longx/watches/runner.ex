defmodule Longx.Watches.Runner do
  @moduledoc """
  One run of one watch (`Longx.Watches.run/2`), as an Oban job: `id` the
  row, `payload` a webhook's body. Never retried — what went wrong is on
  the row, and the next tick queues the next run.
  """

  use Oban.Worker,
    queue: :watches,
    max_attempts: 1,
    unique: [period: 300, keys: [:id], states: [:available, :scheduled, :executing]]

  alias Longx.Watches

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => id} = args}) do
    case Ash.get(Watches.Watch, id) do
      {:ok, watch} ->
        _ = Watches.run(watch, payload: args["payload"])
        :ok

      # the row is gone (the file removed, the project deleted): nothing to run
      {:error, _} ->
        :ok
    end
  end
end
