defmodule Longx.Agent.Kernel.TeamTest do
  use ExUnit.Case, async: false

  alias Longx.Agent.Kernel.{Specs, Team}
  alias Longx.Agent.Kernel.State
  alias Longx.Agent.ThreadState

  test "a restarting parent judges a child working from the view in ETS, never by a call from its init (a call waits on the child's mailbox — up to the whole timeout — and then calls it done while it works)" do
    parent = "native_team_#{System.unique_integer([:positive])}"
    child = "native_child_#{System.unique_integer([:positive])}"
    Specs.put(child, parent: parent, name: "helper", role: "helper", task: "do it", spawned_at: 1)
    on_exit(fn -> Specs.delete(child) end)

    # the child's process stands for itself: alive, and its view says a turn is in flight
    me = self()
    {:ok, _} = Registry.register(Longx.Agent.Registry, child, nil)
    {:ok, _} = ThreadState.ensure(child)
    # an ingest is a cast: wait for the fold's broadcast before reading the view
    ThreadState.subscribe(child)

    ThreadState.ingest(child, "turn/started", %{
      "turn" => %{"id" => "t1", "status" => "inProgress"}
    })

    assert_receive {:thread, _, "turn/started", _}

    # no process is called: a test process that answers nothing is enough
    {elapsed, state} =
      :timer.tc(fn -> Team.restore_children(%State{thread_id: parent, children: %{}}) end)

    assert [%{name: "helper", status: :working, pid: ^me}] = Map.values(state.children)
    assert elapsed < 500_000

    ThreadState.ingest(child, "turn/completed", %{
      "turn" => %{"id" => "t1", "status" => "completed"}
    })

    assert_receive {:thread, _, "turn/completed", _}
    state = Team.restore_children(%State{thread_id: parent, children: %{}})
    assert [%{status: :done}] = Map.values(state.children)
  end
end
