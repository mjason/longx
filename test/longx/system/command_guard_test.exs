defmodule Longx.System.CommandGuardTest do
  use ExUnit.Case, async: true

  alias Longx.System.CommandGuard

  @moduletag :cgroup

  test "the native read-only preflight reports eligibility, never active protection" do
    report = CommandGuard.report(%{command_cgroup_mode: "auto"}, reports: fn -> [] end)
    assert report.capability in ["eligible", "unavailable", "unsupported"]
    assert report.active_tasks == 0
    assert is_binary(report.checked_at)
  end

  test "off never probes, and a non-Linux host is explicitly unsupported" do
    probe = fn -> flunk("must not probe") end
    opts = [platform: {:linux, :x86_64}, probe: probe, reports: fn -> [] end]

    assert %{mode: "off", capability: "off", active_tasks: 0} =
             CommandGuard.report(%{command_cgroup_mode: "off"}, opts)

    assert %{capability: "unsupported", reason: reason} =
             CommandGuard.report(%{command_cgroup_mode: "auto"},
               platform: {:darwin, :aarch64},
               probe: probe,
               reports: fn -> [] end
             )

    assert reason =~ "Linux"
    assert {:error, _} = CommandGuard.start_check("required", {:windows, :x86_64})
    assert :ok = CommandGuard.start_check("auto", {:windows, :x86_64})
  end

  test "eligible is not active protection; Docker is not assumed unavailable" do
    assert %{capability: "eligible", active_tasks: 0, reason: "startup still verifies"} =
             CommandGuard.report(%{command_cgroup_mode: "auto"},
               platform: {:linux, :x86_64},
               probe: fn ->
                 {:ok, %{"status" => "eligible", "reason" => "startup still verifies"}}
               end,
               reports: fn -> [] end
             )
  end

  test "failed or malformed detection cannot claim support" do
    for answer <- [
          {:error, :timeout},
          {:ok, %{"status" => "active"}},
          {:ok, %{"status" => "unavailable", "reason" => "no delegation"}}
        ] do
      assert %{capability: "unavailable", reason: reason} =
               CommandGuard.report(%{command_cgroup_mode: "required"},
                 platform: {:linux, :x86_64},
                 probe: fn -> answer end,
                 reports: fn -> [] end
               )

      assert is_binary(reason) and reason != ""
    end
  end

  test "actual task guard and failed cleanup remain distinct from capability" do
    reports = [
      %{
        live: false,
        sequence: 1,
        guard: %{"status" => "active", "path" => "/task"},
        exit: %{"oom_kill" => 0, "populated" => true, "cleanup_error" => "blocked"}
      }
    ]

    assert %{
             active_tasks: 0,
             cleanup_pending_tasks: 1,
             last_task_status: "active",
             last_populated: true,
             last_cleanup_error: "blocked"
           } =
             CommandGuard.report(%{command_cgroup_mode: "auto"},
               platform: {:linux, :x86_64},
               probe: fn -> {:ok, %{"status" => "eligible"}} end,
               reports: fn -> reports end
             )
  end
end
