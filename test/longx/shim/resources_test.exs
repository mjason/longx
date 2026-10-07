defmodule Longx.Shim.ResourcesTest do
  use ExUnit.Case, async: true

  alias Longx.Shim
  alias Longx.Shim.ResourceReport

  @moduletag :cgroup

  test "fallback warns visibly, but off and active guards do not warn" do
    assert ResourceReport.warning(%{"status" => "unavailable", "reason" => "no delegation"}) =~
             "no delegation"

    assert ResourceReport.warning(%{"status" => "unavailable", "reason" => "no delegation"}) =~
             "WARNING"

    assert ResourceReport.warning(%{"status" => "active"}) == nil
    assert ResourceReport.warning(%{"status" => "off"}) == nil
    assert ResourceReport.warning(nil) == nil
  end

  test "only an oom_kill increment proves OOM, cleanup failures remain visible" do
    assert ResourceReport.exit_reason(%{
             "oom_kill" => 0,
             "populated" => false,
             "cleanup_error" => ""
           }) == nil

    assert ResourceReport.exit_reason(nil) == nil

    assert ResourceReport.exit_reason(%{
             "oom_kill" => 1,
             "populated" => false,
             "cleanup_error" => ""
           }) =~ "memory limit"

    assert ResourceReport.exit_reason(%{
             "oom_kill" => 0,
             "populated" => true,
             "cleanup_error" => ""
           }) =~ "still populated"

    assert ResourceReport.exit_reason(%{
             "oom_kill" => 0,
             "populated" => false,
             "cleanup_error" => "rmdir denied"
           }) =~ "rmdir denied"
  end

  test "job endings preserve person stop, report OOM and keep ordinary signal exits separate" do
    normal = %{"oom_kill" => 0, "populated" => false, "cleanup_error" => ""}
    assert {"exited", nil, false} = ResourceReport.job_end(nil, nil, normal)
    oom = %{normal | "oom_kill" => 1}
    assert {"killed", reason, false} = ResourceReport.job_end(nil, nil, oom)
    assert reason =~ "memory limit"

    assert {"stopped", reason, true} =
             ResourceReport.job_end({"stopped", "by person", true}, "fallback", oom)

    assert reason =~ "by person" and reason =~ "fallback" and reason =~ "memory limit"

    assert {"failed", reason, false} =
             ResourceReport.job_end(nil, nil, %{normal | "cleanup_error" => "permission denied"})

    assert reason =~ "permission denied"
  end

  test "unverified cleanup overrides an OOM or a stop while retaining who stopped it" do
    for {populated, error} <- [{true, ""}, {false, "permission denied"}] do
      report = %{"oom_kill" => 1, "populated" => populated, "cleanup_error" => error}
      assert {"failed", reason, false} = ResourceReport.job_end(nil, nil, report)
      assert reason =~ "memory limit"

      assert {"failed", reason, true} =
               ResourceReport.job_end({"stopped", "by person", true}, "fallback", report)

      assert reason =~ "by person" and reason =~ "fallback"
    end
  end

  test "cleanup diagnostics come before OOM advice, and unknown exit is not invented" do
    report = %{"oom_kill" => 0, "populated" => true, "cleanup_error" => "root still alive"}
    assert {"failed", reason, false} = ResourceReport.job_end(nil, nil, report)
    refute reason =~ "memory limit"
    assert {:exit_status, -1} = Shim.Proto.decode(<<21, -1::signed-big-32>>)

    assert "task cgroup cleanup failed: root still alive" <> _ =
             ResourceReport.exit_reason(%{report | "oom_kill" => 1})
  end

  test "metadata queries return nil when missing and survive the shim exiting" do
    child =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    assert Shim.resource_guard(child) == nil
    assert Shim.resource_exit(child) == nil

    guard = %{
      "status" => "active",
      "reason" => "",
      "path" => "/task",
      "memory_max" => 1,
      "swap_max" => 0
    }

    exit = %{"oom_kill" => 1, "populated" => false, "cleanup_error" => ""}
    Shim.Resources.put(child, :resource_guard, guard)
    Shim.Resources.put(child, :resource_exit, exit)
    ref = Process.monitor(child)
    send(child, :stop)
    assert_receive {:DOWN, ^ref, _, ^child, _}
    assert Shim.resource_guard(child) == guard
    assert Shim.resource_exit(child) == exit
  end

  test "status snapshots only count a live guarded task before its exit report" do
    child = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> if Process.alive?(child), do: send(child, :stop) end)
    path = "/task-#{System.unique_integer([:positive])}"
    Shim.Resources.put(child, :resource_guard, %{"status" => "active", "path" => path})
    report = Enum.find(Shim.Resources.snapshots(), &(&1.guard && &1.guard["path"] == path))
    assert report.live and report.exit == nil
    assert is_integer(report.sequence) and is_binary(report.observed_at)

    Shim.Resources.put(child, :resource_exit, %{
      "oom_kill" => 0,
      "populated" => false,
      "cleanup_error" => ""
    })

    report = Enum.find(Shim.Resources.snapshots(), &(&1.guard && &1.guard["path"] == path))
    refute is_nil(report.exit)

    assert %{active_tasks: 0} =
             Longx.System.CommandGuard.report(%{command_cgroup_mode: "off"},
               reports: fn -> [report] end
             )
  end
end
