defmodule Longx.Jobs.PlugTest do
  # The agent's side of the background jobs: start one under a name, list, read,
  # wait, stop — by name, never by a pid it would have to remember.
  use ExUnit.Case, async: false

  alias Longx.Agent.{Context, Step, Tool}
  alias Longx.Agent.Plugs.{Jobs, Shell}

  setup do
    thread = "native_jobplug_#{System.unique_integer([:positive])}"
    on_exit(fn -> Longx.Jobs.delete(thread) end)
    %{ctx: %Context{cwd: System.tmp_dir!(), thread_id: thread}, thread: thread}
  end

  defp tool!(name),
    do: Enum.find(Jobs.__agent_tools__(), &(&1.name == name)) || flunk("no tool #{name}")

  defp call(name, args, ctx) do
    case Tool.call(tool!(name), args, ctx) do
      {:ok, text} -> text
      {:ok, text, _meta} -> text
      {:error, text} -> {:error, text}
    end
  end

  test "start, list, read, wait, stop — by name", %{ctx: ctx} do
    started =
      call("start_job", %{"name" => "count", "cmd" => "echo one; sleep 0.3; echo two"}, ctx)

    assert started =~ ~s|Job "count" started|
    assert started =~ "you are woken when it ends"

    assert call("jobs", %{}, ctx) =~ ~r/count\s+running/

    # a running name refuses another start
    assert {:error, refused} = call("start_job", %{"name" => "count", "cmd" => "true"}, ctx)
    assert refused =~ ~s|"count" is already running|

    ended = call("wait_job", %{"name" => "count", "timeout_ms" => 5_000}, ctx)
    assert ended =~ "exited with code 0"
    assert ended =~ "two"

    assert call("job_output", %{"name" => "count", "tail" => 1}, ctx) =~ ~r/two\n?$/
    assert call("job_output", %{"name" => "count", "grep" => "one"}, ctx) =~ "one"

    call("start_job", %{"name" => "server", "cmd" => "sleep 30"}, ctx)
    assert call("stop_job", %{"name" => "server"}, ctx) =~ ~s|Job "server" stopped|
    assert call("jobs", %{}, ctx) =~ ~r/server\s+stopped/
  end

  test "a bad name, an unknown job, an empty list say so", %{ctx: ctx} do
    assert call("jobs", %{}, ctx) =~ "No background jobs"
    assert {:error, bad} = call("start_job", %{"name" => "../x", "cmd" => "true"}, ctx)
    assert bad =~ "letters, digits"
    assert {:error, unknown} = call("job_output", %{"name" => "nope"}, ctx)
    assert unknown =~ ~s|no job "nope"|
  end

  test "exec_command points long commands at start_job, never at nohup" do
    exec = Enum.find(Shell.__agent_tools__(), &(&1.name == "exec_command"))
    refute exec.description =~ "nohup …"
    assert exec.description =~ "start_job"
  end

  test "the shipped pipeline has the jobs right after the shell" do
    names = Enum.map(Longx.Agent.Pipelines.Default.plugs(), &elem(&1, 0))
    assert [Shell, Jobs | _] = Enum.drop_while(names, &(&1 != Shell))
  end

  test "newly reviewed failures get one actionable hand-off, not just a ledger entry", %{
    thread: thread,
    ctx: ctx
  } do
    step = Jobs.call(Step.new(thread_id: thread), [])
    {:ok, job} = Longx.Jobs.start(thread, "failed", "exit 1", notify: false)
    {:ok, _} = Longx.Jobs.wait(thread, "failed", 5_000)
    ending = %{step | phase: :turn_end}
    unreviewed = Jobs.call(ending, [])
    assert [{:continue, review_text, _}] = unreviewed.effects
    assert review_text =~ "not yet reviewed"

    assert call(
             "review_job",
             %{
               "name" => job.name,
               "run" => job.run,
               "outcome" => "incomplete",
               "note" => "differs"
             },
             ctx
           ) =~ "Recorded incomplete"

    followup = Jobs.call(%{unreviewed | effects: []}, [])
    assert [{:continue, text, origin}] = followup.effects
    assert origin["status"] == "followup"
    assert text =~ "continue diagnosis or repair"
    assert text =~ "specific blocker"
    assert text =~ "original authorization"
    assert text =~ "Do not restart person-stopped work"
    assert text =~ job.run
    assert text =~ "differs"
    assert [%{review: "incomplete"}] = Longx.Jobs.pending(thread)
    assert Jobs.call(%{followup | effects: []}, []).effects == []
    # Reaffirming a failure does not create an endless continuation loop.
    {:ok, _} = Longx.Jobs.review(thread, job.name, job.run, "incomplete", "needs new authority")
    assert Jobs.call(%{followup | effects: []}, []).effects == []
    # Nor does an unrelated new turn revive the historical failure.
    next = Jobs.call(Step.new(thread_id: thread), [])
    assert Jobs.call(%{next | phase: :turn_end}, []).effects == []
  end

  test "stopped, background and verified work do not cause repair continuations", %{
    thread: thread
  } do
    step = Jobs.call(Step.new(thread_id: thread), [])
    {:ok, stopped} = Longx.Jobs.start(thread, "stopped", "sleep 30", notify: false)
    {:ok, _} = Longx.Jobs.stop(thread, stopped.name, by: :person)

    {:ok, _} =
      Longx.Jobs.review(thread, stopped.name, stopped.run, "incomplete", "person stopped")

    assert Jobs.call(%{step | phase: :turn_end}, []).effects == []

    {:ok, background} =
      Longx.Jobs.start(thread, "service", "exit 1", notify: false, purpose: "background")

    {:ok, _} = Longx.Jobs.wait(thread, background.name, 5_000)
    {:ok, _} = Longx.Jobs.review(thread, background.name, background.run, "incomplete", "service")
    assert Jobs.call(%{step | phase: :turn_end}, []).effects == []

    {:ok, good} = Longx.Jobs.start(thread, "verified", "true", notify: false)
    {:ok, _} = Longx.Jobs.wait(thread, good.name, 5_000)
    {:ok, _} = Longx.Jobs.review(thread, good.name, good.run, "complete", "verified")
    # Existing reconciliation is still required, but is never a repair mandate.
    reconciled = Jobs.call(%{step | phase: :turn_end}, [])
    assert [{:continue, text, _}] = reconciled.effects
    assert text =~ "Reconcile stopped"
    refute text =~ "continue diagnosis or repair"
    assert Jobs.call(%{reconciled | effects: []}, []).effects == []
  end

  test "a new run under an old name is followed up by exact run, not name", %{thread: thread} do
    {:ok, old} = Longx.Jobs.start(thread, "check", "exit 1", notify: false)
    {:ok, _} = Longx.Jobs.wait(thread, old.name, 5_000)
    {:ok, _} = Longx.Jobs.review(thread, old.name, old.run, "incomplete", "old")
    step = Jobs.call(Step.new(thread_id: thread), [])
    {:ok, new} = Longx.Jobs.start(thread, old.name, "exit 2", notify: false)
    {:ok, _} = Longx.Jobs.wait(thread, new.name, 5_000)
    {:ok, _} = Longx.Jobs.review(thread, new.name, new.run, "incomplete", "new")
    followed = Jobs.call(%{step | phase: :turn_end}, [])
    assert [{:continue, text, _}] = followed.effects
    assert text =~ new.run
    refute text =~ old.run
    assert Jobs.call(%{followed | effects: []}, []).effects == []
  end

  test "an unverified successful exit needs a hand-off, but a verified replacement clears it", %{
    thread: thread
  } do
    step = Jobs.call(Step.new(thread_id: thread), [])
    {:ok, old} = Longx.Jobs.start(thread, "unverified", "true", notify: false)
    {:ok, _} = Longx.Jobs.wait(thread, old.name, 5_000)
    {:ok, _} = Longx.Jobs.review(thread, old.name, old.run, "incomplete", "output not verified")
    ending = %{step | phase: :turn_end}
    assert [{:continue, text, _}] = Jobs.call(ending, []).effects
    assert text =~ "output not verified"

    {:ok, good} = Longx.Jobs.start(thread, "replacement", "true", notify: false)
    {:ok, _} = Longx.Jobs.wait(thread, good.name, 5_000)

    {:ok, _} =
      Longx.Jobs.review(thread, good.name, good.run, "complete", "verified replacement",
        supersedes: [old.run]
      )

    assert Jobs.call(ending, []).effects == []
    assert Longx.Jobs.pending(thread) == []
  end
end
