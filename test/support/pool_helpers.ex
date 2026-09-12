defmodule Longx.Test.PoolHelpers do
  @moduledoc """
  Cleanup for tests that use the per-project codex pool: stop the workers,
  then let `Longx.Projects.Tracker` (and the resume tasks it spawns) finish
  reacting to the `:down`/`:ready` broadcasts *before* the test's DB sandbox
  goes away — otherwise they log ownership errors into the next test.
  """

  alias Longx.Codex.Pool

  @spec stop_pool!([String.t()]) :: :ok
  def stop_pool!(project_ids) do
    Enum.each(project_ids, &Pool.stop(&1, force: true))
    drain_tracker!()
  end

  @spec drain_tracker!() :: :ok
  def drain_tracker! do
    wait_tasks(50)
    # a synchronous round-trip: everything already in the mailbox is handled
    _ = :sys.get_state(Longx.Projects.Tracker)
    :ok
  end

  defp wait_tasks(0), do: :ok

  defp wait_tasks(attempts) do
    case Task.Supervisor.children(Longx.Codex.TaskSupervisor) do
      [] -> :ok
      _ -> Process.sleep(20) && wait_tasks(attempts - 1)
    end
  end
end
