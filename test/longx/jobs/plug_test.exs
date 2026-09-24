defmodule Longx.Jobs.PlugTest do
  # The agent's side of the background jobs: start one under a name, list, read,
  # wait, stop — by name, never by a pid it would have to remember.
  use ExUnit.Case, async: false

  alias Longx.Agent.{Context, Tool}
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
end
