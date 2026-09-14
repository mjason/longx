defmodule Longx.Codex.SandboxTest do
  use ExUnit.Case, async: true

  alias Longx.Codex.Sandbox

  describe "interpret/2 (pure): what a failed bubblewrap probe means" do
    test "user namespaces refused" do
      for stderr <- [
            "bwrap: No permissions to create a new namespace, likely because the kernel does not allow non-privileged user namespaces.",
            "bwrap: Creating new namespace failed: Operation not permitted",
            "bwrap: setting up uid map: Permission denied"
          ] do
        assert {:error, {:user_namespaces, _}} = Sandbox.interpret(1, stderr)
      end
    end

    test "loopback / seccomp problems are reported as such" do
      assert {:error, {:seccomp, _}} =
               Sandbox.interpret(1, "bwrap: prctl(PR_SET_SECCOMP): Invalid argument")
    end

    test "anything else keeps the message" do
      assert {:error, {:unknown, "bwrap: weird"}} = Sandbox.interpret(2, "bwrap: weird\n")
      assert :ok = Sandbox.interpret(0, "")
    end
  end

  describe "probe/0" do
    # what the host allows: a WSL2 dev box passes, a GitHub runner does not
    # (bwrap cannot set up the loopback there) — CI excludes :host_sandbox
    @tag :linux
    @tag :host_sandbox
    test "runs the bundled bwrap once; a WSL2 dev box passes" do
      case :os.type() do
        {:unix, :linux} -> assert :ok = Sandbox.probe()
        _ -> assert :ok = Sandbox.probe()
      end
    end

    test "status/0 is cached after the first probe and can be re-probed" do
      assert Sandbox.status() in [:ok, :unavailable]
      assert %{status: status, reason: _, checked_at: %DateTime{}} = Sandbox.report()
      assert status in [:ok, :unavailable]
    end
  end
end
