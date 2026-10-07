defmodule Longx.Test.CgroupE2EModelTest do
  use ExUnit.Case, async: true

  alias Longx.Test.CgroupE2EModel

  defp request(text, extra \\ []) do
    %{
      "model" => "cgroup-e2e",
      "input" => [
        %{"role" => "user", "content" => [%{"type" => "input_text", "text" => text}]} | extra
      ]
    }
  end

  test "only fixed test markers select bounded foreground or background commands" do
    assert {:ok, %{tool: "exec_command", arguments: foreground}} =
             CgroupE2EModel.plan(request("CGROUP_E2E exec auto-1"), "/scratch/evidence")

    assert foreground["login"] == false
    assert foreground["timeout_ms"] == 40_000
    assert foreground["cmd"] =~ "/proc/self/cgroup"
    assert foreground["cmd"] =~ "auto-1.release"
    assert foreground["cmd"] =~ "sleep 6"
    assert foreground["cmd"] =~ "cgroup_e2e_tick -lt 30"

    assert {:ok, %{tool: "start_job", arguments: background}} =
             CgroupE2EModel.plan(request("CGROUP_E2E job auto-job"), "/scratch/evidence")

    assert background["notify"] == false
    assert background["name"] == "auto-job"
    assert background["cmd"] =~ "auto-job.membership"
  end

  test "the real tool's output ends the model turn instead of issuing the command twice" do
    output = %{"type" => "function_call_output", "call_id" => "test", "output" => "actual output"}

    assert {:ok, %{answer: "CGROUP_E2E_DONE held"}} =
             CgroupE2EModel.plan(request("CGROUP_E2E exec held", [output]), "/scratch")
  end

  test "a later user marker is not mistaken for an earlier completed tool" do
    earlier = %{"type" => "function_call_output", "output" => "old output"}
    newer = %{"role" => "user", "content" => "CGROUP_E2E job newest"}

    assert {:ok, %{tool: "start_job", arguments: %{"name" => "newest"}}} =
             CgroupE2EModel.plan(request("CGROUP_E2E exec old", [earlier, newer]), "/scratch")
  end

  test "unrelated models, unrecognised messages and shell metacharacters are refused" do
    assert {:error, _} =
             CgroupE2EModel.plan(
               %{request("CGROUP_E2E exec safe") | "model" => "paid"},
               "/scratch"
             )

    assert {:error, _} = CgroupE2EModel.plan(request("run arbitrary command"), "/scratch")

    assert {:error, _} =
             CgroupE2EModel.plan(request("CGROUP_E2E exec unsafe;echo hi"), "/scratch")
  end
end
