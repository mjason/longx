defmodule Longx.Tls.RenewWorker do
  @moduledoc """
  Once a day (`config :longx, Oban` cron): obtains the HTTPS certificate
  when `Longx.Tls.Manager.due?/3` says so — HTTPS on and no certificate,
  other names, or less than 30 days left. The issuance runs in the manager;
  its failure is shown on the settings page and recorded there.
  """

  use Oban.Worker, queue: :tls, max_attempts: 1, unique: [period: 3_600]

  @impl Oban.Worker
  def perform(_job) do
    _ = Longx.Tls.Manager.renew_if_due()
    :ok
  end
end
