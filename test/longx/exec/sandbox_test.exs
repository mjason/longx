defmodule Longx.Exec.SandboxTest do
  use ExUnit.Case, async: true

  alias Longx.Exec.{Policy, Sandbox}

  @entries [
    %{"access" => "read", "path" => %{"type" => "special", "value" => %{"kind" => "root"}}},
    %{
      "access" => "write",
      "path" => %{"type" => "special", "value" => %{"kind" => "project_roots"}}
    },
    %{"access" => "write", "path" => %{"type" => "special", "value" => %{"kind" => "slash_tmp"}}},
    %{"access" => "write", "path" => %{"type" => "special", "value" => %{"kind" => "tmpdir"}}},
    %{
      "access" => "read",
      "missing_path_behavior" => "skip",
      "path" => %{
        "type" => "special",
        "value" => %{"kind" => "project_roots", "subpath" => ".git"}
      }
    },
    %{
      "access" => "read",
      "missing_path_behavior" => "skip",
      "path" => %{
        "type" => "special",
        "value" => %{"kind" => "project_roots", "subpath" => ".codex"}
      }
    }
  ]

  defp context(network \\ "restricted", entries \\ @entries) do
    %{
      "cwd" => "file:///home/mj/proj",
      "workspaceRoots" => ["file:///home/mj/proj"],
      "permissions" => %{
        "type" => "managed",
        "network" => network,
        "file_system" => %{"type" => "restricted", "entries" => entries}
      }
    }
  end

  @existing [
    "/home/mj/proj",
    "/home/mj/proj/.git",
    "/tmp",
    "/dev/nvidia0",
    "/dev/dxg",
    "/run/x.sock"
  ]
  defp opts(over \\ []) do
    Keyword.merge(
      [
        platform: {:linux, :x86_64},
        bwrap: "/usr/bin/bwrap",
        exists?: &(&1 in @existing),
        tmpdir: nil
      ],
      over
    )
  end

  defp policy!(ctx), do: elem(Policy.parse(ctx, tmpdir: nil, exists?: &(&1 in @existing)), 1)

  describe "Linux (bubblewrap)" do
    test "workspace-write without network: root read-only, the roots writable, .git read-only inside, no network" do
      assert {:ok, {:bwrap, argv}} =
               Sandbox.wrap(policy!(context()), ["/bin/bash", "-lc", "ls"], opts())

      assert argv == [
               "/usr/bin/bwrap",
               "--new-session",
               "--die-with-parent",
               "--ro-bind",
               "/",
               "/",
               "--dev",
               "/dev",
               "--bind",
               "/tmp",
               "/tmp",
               "--bind",
               "/home/mj/proj",
               "/home/mj/proj",
               "--ro-bind",
               "/home/mj/proj/.git",
               "/home/mj/proj/.git",
               "--unshare-user",
               "--unshare-pid",
               "--unshare-ipc",
               "--unshare-net",
               "--proc",
               "/proc",
               "--cap-drop",
               "ALL",
               "--",
               "/bin/bash",
               "-lc",
               "ls"
             ]
    end

    test "network on: the namespace stays; a policy that is not sandboxed but has no network still loses the network" do
      assert {:ok, {:bwrap, argv}} = Sandbox.wrap(policy!(context("enabled")), ["ls"], opts())
      refute "--unshare-net" in argv

      full =
        context("restricted", [
          %{"access" => "write", "path" => %{"type" => "special", "value" => %{"kind" => "root"}}}
        ])

      assert {:ok, {:bwrap, argv}} = Sandbox.wrap(policy!(full), ["ls"], opts())
      assert Enum.slice(argv, 3, 3) == ["--bind", "/", "/"]
      assert "--unshare-net" in argv
    end

    test "nothing to enforce runs the command as it is" do
      full =
        context("enabled", [
          %{"access" => "write", "path" => %{"type" => "special", "value" => %{"kind" => "root"}}}
        ])

      assert {:ok, {:none, ["ls", "-la"]}} = Sandbox.wrap(policy!(full), ["ls", "-la"], opts())
      assert {:ok, {:none, ["ls"]}} = Sandbox.wrap(policy!(nil), ["ls"], opts())
    end

    test "passthrough: devices go in right after --dev /dev, other paths as plain binds, missing ones skipped" do
      opts = opts(passthrough: ["/dev/nvidia0", "/dev/nvidia9", "/run/x.sock", "/dev/dxg"])
      assert {:ok, {:bwrap, argv}} = Sandbox.wrap(policy!(context()), ["ls"], opts)

      assert Enum.slice(argv, 6, 11) == [
               "--dev",
               "/dev",
               "--dev-bind",
               "/dev/dxg",
               "/dev/dxg",
               "--dev-bind",
               "/dev/nvidia0",
               "/dev/nvidia0",
               "--bind",
               "/run/x.sock",
               "/run/x.sock"
             ]
    end

    test "no /proc when the host cannot mount it; a missing writable root is not bound" do
      opts = opts(proc: false, exists?: &(&1 in ["/home/mj/proj"]))
      assert {:ok, {:bwrap, argv}} = Sandbox.wrap(policy!(context()), ["ls"], opts)
      refute "--proc" in argv
      refute "/tmp" in argv
    end

    test "without bubblewrap a sandboxed command is refused, never run open" do
      assert {:error, :no_bwrap} = Sandbox.wrap(policy!(context()), ["ls"], opts(bwrap: nil))
    end
  end

  describe "macOS (seatbelt)" do
    test "a profile with the writable roots as parameters, read-only pockets excluded, no network section when restricted" do
      assert {:ok, {:seatbelt, ["/usr/bin/sandbox-exec", "-p", profile | rest]}} =
               Sandbox.wrap(policy!(context()), ["ls"], opts(platform: {:darwin, :aarch64}))

      assert profile =~ "(deny default)"
      assert profile =~ "(allow file-read*)"
      assert profile =~ ~s[(subpath (param "WRITABLE_ROOT_0"))]
      assert profile =~ ~s[(require-not (subpath (param "WRITABLE_ROOT_0_EXCLUDED_0")))]
      refute profile =~ "network-outbound"
      assert "-DWRITABLE_ROOT_0=/home/mj/proj" in rest
      assert "-DWRITABLE_ROOT_0_EXCLUDED_0=/home/mj/proj/.git" in rest
      assert "-DWRITABLE_ROOT_1=/tmp" in rest
      assert Enum.take(rest, -2) == ["--", "ls"]
    end

    test "network on adds the outbound rules" do
      assert {:ok, {:seatbelt, [_, "-p", profile | _]}} =
               Sandbox.wrap(
                 policy!(context("enabled")),
                 ["ls"],
                 opts(platform: {:darwin, :x86_64})
               )

      assert profile =~ "(allow network-outbound)"
      assert profile =~ "com.apple.SecurityServer"
    end
  end

  test "another platform cannot sandbox" do
    assert {:error, :unsupported} =
             Sandbox.wrap(policy!(context()), ["ls"], opts(platform: {:windows, :x86_64}))
  end
end
