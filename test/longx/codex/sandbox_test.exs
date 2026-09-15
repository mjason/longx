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

  describe "evaluate/1 (pure): the probe as codex would run bwrap, in two steps" do
    # the runner gets bwrap's arguments and answers {status, stderr}
    defp runner(answers) do
      fn args ->
        cond do
          "--unshare-net" in args -> answers[:net]
          "--proc" in args -> answers[:base]
          true -> answers[:no_proc] || answers[:base]
        end
      end
    end

    test "user / pid / ipc namespaces and the network namespace both work → ok" do
      assert :ok = Sandbox.evaluate(runner(base: {0, ""}, net: {0, ""}))
    end

    test "the flags are codex's own, not --unshare-all, and the command is /bin/true" do
      assert :ok =
               Sandbox.evaluate(fn args ->
                 assert "--unshare-user" in args and "--unshare-pid" in args and
                          "--unshare-ipc" in args

                 refute "--unshare-all" in args
                 assert List.last(args) == "/bin/true"
                 {0, ""}
               end)
    end

    test "namespaces refused → unavailable, whatever the network step would say" do
      # pinned: a GitHub runner has Ubuntu's AppArmor restriction on, which is its own reason
      assert {:error, {:user_namespaces, msg}} =
               Sandbox.evaluate(
                 runner(base: {1, "bwrap: setting up uid map: Permission denied"}, net: {0, ""}),
                 apparmor_restricted: false
               )

      assert msg =~ "uid map"
    end

    test "namespaces refused while Ubuntu's AppArmor restriction is on → apparmor, the fix is a profile" do
      assert {:error, {:apparmor, msg}} =
               Sandbox.evaluate(
                 runner(base: {1, "bwrap: setting up uid map: Permission denied"}, net: {0, ""}),
                 apparmor_restricted: true
               )

      assert msg =~ "uid map"
      # the same failure without the restriction stays what it is
      assert {:error, {:user_namespaces, _}} =
               Sandbox.evaluate(
                 runner(base: {1, "bwrap: setting up uid map: Permission denied"}, net: {0, ""}),
                 apparmor_restricted: false
               )
    end

    test "only the network namespace fails (a host that cannot set up the loopback) → network isolation unavailable" do
      assert {:error, {:network_isolation, msg}} =
               Sandbox.evaluate(
                 runner(
                   base: {0, ""},
                   net: {1, "bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted"}
                 )
               )

      assert msg =~ "RTM_NEWADDR"
    end

    test "a /proc that cannot be mounted is retried without it, like codex does" do
      assert :ok =
               Sandbox.evaluate(
                 runner(
                   base: {1, "bwrap: Can't mount proc on /newroot/proc: Operation not permitted"},
                   no_proc: {0, ""},
                   net: {0, ""}
                 )
               )
    end
  end

  describe "choose_bwrap/3 (pure): the bwrap codex will run" do
    # codex (linux-sandbox/src/launcher.rs) prefers a `bwrap` on PATH whose
    # --help lists --perms, and falls back to the bundled one
    test "a system bwrap with --perms wins over the bundled one" do
      assert {:system, "/usr/bin/bwrap"} =
               Sandbox.choose_bwrap(
                 "/usr/bin/bwrap",
                 "usage: bwrap … --perms OCTAL …",
                 {:ok, "/b/bwrap"}
               )
    end

    test "an old system bwrap without --perms is ignored" do
      assert {:bundled, "/b/bwrap"} =
               Sandbox.choose_bwrap(
                 "/usr/bin/bwrap",
                 "usage: bwrap --ro-bind …",
                 {:ok, "/b/bwrap"}
               )
    end

    test "no system bwrap → the bundled one; neither → not installed" do
      assert {:bundled, "/b/bwrap"} = Sandbox.choose_bwrap(nil, "", {:ok, "/b/bwrap"})
      assert {:error, :not_installed} = Sandbox.choose_bwrap(nil, "", {:error, :not_installed})
    end
  end

  describe "gpu?/1 (pure): does this machine have an NVIDIA GPU the sandbox will hide" do
    test "nvidia device nodes among /dev's entries" do
      assert Sandbox.gpu?(~w(/dev/null /dev/nvidia0 /dev/nvidiactl))
      refute Sandbox.gpu?(~w(/dev/null /dev/dri /dev/tty))
    end
  end

  describe "presets/1 (pure): host paths worth letting into the sandbox on this machine" do
    test "GPU nodes, USB / serial, the docker socket — only the groups that exist, docker flagged dangerous" do
      entries =
        ~w(/dev/null /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm /dev/dri /dev/bus/usb /dev/ttyUSB0 /dev/ttyACM3 /dev/snd /var/run/docker.sock)

      assert [
               %{
                 id: "gpu",
                 paths: ~w(/dev/dri /dev/nvidia-uvm /dev/nvidia0 /dev/nvidiactl),
                 danger: false
               },
               %{id: "usb", paths: ~w(/dev/bus/usb /dev/ttyACM3 /dev/ttyUSB0), danger: false},
               %{id: "docker", paths: ["/var/run/docker.sock"], danger: true}
             ] = Sandbox.presets(entries)

      assert [%{id: "gpu", paths: ["/dev/dxg"]}] = Sandbox.presets(~w(/dev/null /dev/dxg))
      assert Sandbox.presets(~w(/dev/null /dev/tty)) == []
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
      assert Sandbox.status() in [:ok, :no_net_isolation, :unavailable]

      assert %{status: status, reason: _, bwrap: bwrap, gpu: gpu, checked_at: %DateTime{}} =
               Sandbox.report()

      assert is_boolean(gpu)

      assert status in [:ok, :no_net_isolation, :unavailable]
      assert is_binary(bwrap) or is_nil(bwrap)
    end
  end
end
