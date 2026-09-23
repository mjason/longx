defmodule Longx.Agent.WatchTest do
  @moduledoc """
  `Longx.Agent.Watch`: the module a watch file defines — its schedule read
  off the head, its `run/1` with the helpers, a dry run that records what
  it would send.
  """
  use ExUnit.Case, async: true

  alias Longx.Agent.Watch

  defmodule Health do
    use Longx.Agent.Watch

    every("*/5 * * * *")
    expires("2030-01-01T00:00:00Z")
    max_runs(24)
    budget(3)

    def run(ctx) do
      {code, out} = shell(ctx, "echo up; exit 0")
      status = if code == 0, do: :ok, else: :fail
      log(ctx, "checked: #{String.trim(out)}")

      if status != ctx.state[:status],
        do: send(ctx, "main", "status is now #{status} (#{ctx.name})")

      {:ok, %{status: status}}
    end
  end

  defmodule Once do
    use Longx.Agent.Watch
    once("2030-05-01T08:00:00+08:00")
    def run(ctx), do: send(ctx, :self, "time to look again") |> then(fn _ -> {:ok, %{}} end)
  end

  defmodule Hook do
    use Longx.Agent.Watch
    webhook(true)
    def run(ctx), do: {:ok, %{last: ctx.payload}}
  end

  defmodule BadCron do
    use Longx.Agent.Watch
    every("not a cron")
    def run(_ctx), do: {:ok, %{}}
  end

  defmodule NoSchedule do
    use Longx.Agent.Watch
    def run(_ctx), do: {:ok, %{}}
  end

  defmodule Crashes do
    use Longx.Agent.Watch
    every("* * * * *")
    def run(_ctx), do: raise("boom")
  end

  test "the head is the definition: kind, cron, limits; the next time is computed" do
    assert {:ok, d} = Watch.definition(Health)
    assert d.kind == :cron
    assert d.cron == "*/5 * * * *"
    assert d.max_runs == 24
    assert d.budget == 3
    assert d.timeout == 30_000
    assert %DateTime{} = d.expires_at
    assert %DateTime{} = next = Watch.next_due_at(d, ~U[2026-09-18 10:02:00Z])
    assert DateTime.compare(next, ~U[2026-09-18 10:02:00Z]) == :gt
    assert next.minute in [5, 10]

    assert {:ok, %{kind: :once, at: %DateTime{} = at}} = Watch.definition(Once)
    assert DateTime.to_iso8601(at) == "2030-05-01T00:00:00Z"
    assert Watch.next_due_at(Watch.definition!(Once), ~U[2026-01-01 00:00:00Z]) == at

    assert {:ok, %{kind: :webhook}} = Watch.definition(Hook)
    assert Watch.next_due_at(Watch.definition!(Hook), ~U[2026-01-01 00:00:00Z]) == nil

    assert {:error, message} = Watch.definition(BadCron)
    assert message =~ "cron"
    assert {:error, message} = Watch.definition(NoSchedule)
    assert message =~ "every"
    assert {:error, _} = Watch.definition(String)
  end

  test "a run: the helpers work, the sends go through the delivery given, the state comes back" do
    sent = self()

    deliver = fn to, text, opts ->
      Kernel.send(sent, {:sent, to, text, opts})
      :ok
    end

    ctx = %{name: "health", project_root: File.cwd!(), state: %{}, deliver: deliver}
    assert %{result: {:ok, %{status: :ok}}, sends: sends, log: log} = Watch.run(Health, ctx)
    assert [%{to: "main", text: "status is now ok (health)"}] = sends
    assert log == ["checked: up"]
    assert_receive {:sent, "main", "status is now ok (health)", _}

    # nothing changed: nothing sent
    assert %{result: {:ok, _}, sends: []} = Watch.run(Health, %{ctx | state: %{status: :ok}})

    # a dry run records without delivering
    assert %{sends: [%{to: :self, text: "time to look again"}]} =
             Watch.run(Once, %{ctx | deliver: :dry})

    refute_receive {:sent, _, _, _}

    # a crash is a result, not an exception
    assert %{result: {:error, message}} = Watch.run(Crashes, ctx)
    assert message =~ "boom"
  end

  # like exec_command: nothing to read — `rg pattern` with no path searches the
  # directory instead of an empty pipe
  test "shell/3 gives the command the null device as stdin, not a pipe" do
    assert {0, "not piped\nend\n"} =
             Watch.Helpers.shell(
               %{project_root: System.tmp_dir!()},
               "[ -p /dev/stdin ] && echo piped || echo not piped; cat; echo end"
             )
  end
end
