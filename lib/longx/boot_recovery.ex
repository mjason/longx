defmodule Longx.BootRecovery do
  @moduledoc """
  Settles work left by the previous BEAM before the Tracker, scheduler or
  endpoint can start. Like the boot migrator, this synchronous one-shot
  child returns `:ignore` once done.

  An asynchronous task after the Tracker raced its recovery: an ordinary
  upgrade was reported as an agent crash (LONX-M), and late cleanup could
  fail a new turn or clear a newly started watch. A Tracker-only restart
  still recovers and reports orphaned turns; it does not rerun this child.
  """

  @spec child_spec(keyword) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  @spec start_link(keyword) :: :ignore
  def start_link(_opts) do
    Longx.Projects.settle_after_restart()
    :ok = Longx.Watches.settle_after_restart()
    Longx.Jobs.settle_after_restart()
    :ignore
  end
end
