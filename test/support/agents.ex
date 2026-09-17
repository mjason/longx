defmodule Longx.Test.Agents do
  @moduledoc """
  Tears every thread's agent down at the end of a test that ran the kernel
  through `Longx.Projects`, in the order that leaves no writer behind: the
  agents (their turns interrupted, their last events emitted), the
  ThreadState writers (their casts folded), then the Tracker drained — it
  writes turn rows on those events, and a write landing after the
  sandbox is gone hits the next test's connection ("Database busy").
  """

  alias Longx.Agent
  alias Longx.Agent.ThreadState

  @spec stop_all!() :: :ok
  def stop_all! do
    threads = Ash.read!(Longx.Projects.Thread, authorize?: false)

    for t <- threads do
      Agent.stop(t.kernel_thread_id)
      ThreadState.stop(t.kernel_thread_id)
    end

    # a synchronous call answers after everything queued before it
    _ = :sys.get_state(Longx.Projects.Tracker)

    for t <- threads, do: ThreadState.Store.delete(t.kernel_thread_id)
    :ok
  end
end
