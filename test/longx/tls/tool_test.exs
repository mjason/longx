defmodule Longx.Tls.ToolTest do
  @moduledoc """
  The certificate tool (`longx-cert`, github.com/mjason/longx-cert): a pinned
  release with a sha256 per target, installed under
  `<dir>/<version>/<target>/` from a local archive through the same
  verify / extract / replace path the real download takes.
  """
  use ExUnit.Case, async: false

  alias Longx.Tls.Tool

  setup do
    root = Path.join(System.tmp_dir!(), "longx-cert-tool-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, dir: Path.join(root, "install")}
  end

  describe "release pin" do
    test "the version, and one archive per target named after Go's os-arch" do
      assert Tool.version() =~ ~r/^\d+\.\d+\.\d+$/
      assert Tool.asset_name("linux-amd64") == "longx-cert-linux-amd64.tar.gz"
      assert Tool.asset_name("windows-arm64") == "longx-cert-windows-arm64.zip"

      assert Tool.asset_url("darwin-arm64") ==
               "https://github.com/mjason/longx-cert/releases/download/v#{Tool.version()}/longx-cert-darwin-arm64.tar.gz"
    end

    test "every platform Longx runs on has a target, and every target a pinned sha256" do
      for {platform, target} <- [
            {{:linux, :x86_64}, "linux-amd64"},
            {{:linux, :aarch64}, "linux-arm64"},
            {{:darwin, :x86_64}, "darwin-amd64"},
            {{:darwin, :aarch64}, "darwin-arm64"},
            {{:windows, :x86_64}, "windows-amd64"},
            {{:windows, :aarch64}, "windows-arm64"}
          ] do
        assert Tool.target(platform) == target
        assert {:ok, sha} = Tool.sha256(target)
        assert sha =~ ~r/^[0-9a-f]{64}$/
      end

      assert {:error, :unsupported_target} = Tool.sha256("plan9-386")
    end
  end

  describe "install/2 from a local archive" do
    test "tar.gz: verified, unpacked, the binary found at the root", ctx do
      archive = Path.join(ctx.root, "tool.tar.gz")

      tarball(archive, [
        {"longx-cert", "#!/bin/sh\necho fake\n", 0o755},
        {"LICENSE", "MIT", 0o644}
      ])

      assert {:ok, exe} =
               Tool.install("linux-amd64",
                 source: {:file, archive},
                 sha256: sha(archive),
                 dir: ctx.dir
               )

      assert exe == Path.join([ctx.dir, Tool.version(), "linux-amd64", "longx-cert"])
      assert File.exists?(exe)
      assert Tool.installed?("linux-amd64", dir: ctx.dir)
      assert {:ok, :downloaded, ^exe} = Tool.resolve("linux-amd64", dir: ctx.dir)
    end

    test "zip for windows, with .exe", ctx do
      archive = Path.join(ctx.root, "tool.zip")

      {:ok, _} =
        :zip.create(String.to_charlist(archive), [
          {~c"longx-cert.exe", "MZ"},
          {~c"LICENSE", "MIT"}
        ])

      assert {:ok, exe} =
               Tool.install("windows-amd64",
                 source: {:file, archive},
                 sha256: sha(archive),
                 dir: ctx.dir
               )

      assert String.ends_with?(exe, "windows-amd64/longx-cert.exe")
    end

    test "a checksum that does not match, or an archive without the binary, installs nothing",
         ctx do
      archive = Path.join(ctx.root, "tool.tar.gz")
      tarball(archive, [{"LICENSE", "MIT", 0o644}])

      assert {:error, {:checksum_mismatch, _}} =
               Tool.install("linux-amd64",
                 source: {:file, archive},
                 sha256: String.duplicate("0", 64),
                 dir: ctx.dir
               )

      assert {:error, {:extract_failed, {:missing_executable, _}}} =
               Tool.install("linux-amd64",
                 source: {:file, archive},
                 sha256: sha(archive),
                 dir: ctx.dir
               )

      refute Tool.installed?("linux-amd64", dir: ctx.dir)
      assert {:error, :not_installed} = Tool.resolve("linux-amd64", dir: ctx.dir)
    end
  end

  describe "resolution" do
    test "LONGX_CERT names the binary to run", ctx do
      System.put_env("LONGX_CERT", "/opt/longx-cert")
      on_exit(fn -> System.delete_env("LONGX_CERT") end)
      assert {:ok, :env, "/opt/longx-cert"} = Tool.resolve("linux-amd64", dir: ctx.dir)
    end

    test "an older download stands in until the pinned one is there; prune_old removes it", ctx do
      old = Path.join([ctx.dir, "0.0.1", "linux-amd64", "longx-cert"])
      File.mkdir_p!(Path.dirname(old))
      File.write!(old, "old")
      assert {:ok, :downloaded, ^old} = Tool.resolve("linux-amd64", dir: ctx.dir)
      refute Tool.installed?("linux-amd64", dir: ctx.dir)

      pinned = Path.join([ctx.dir, Tool.version(), "linux-amd64", "longx-cert"])
      File.mkdir_p!(Path.dirname(pinned))
      File.write!(pinned, "new")
      assert {:ok, :downloaded, ^pinned} = Tool.resolve("linux-amd64", dir: ctx.dir)

      :ok = Tool.prune_old("linux-amd64", dir: ctx.dir)
      refute File.exists?(old)
      assert File.exists?(pinned)
    end
  end

  defp sha(path), do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

  defp tarball(path, files) do
    staging = path <> ".d"

    entries =
      for {name, content, mode} <- files do
        full = Path.join(staging, name)
        File.mkdir_p!(Path.dirname(full))
        File.write!(full, content)
        File.chmod!(full, mode)
        {String.to_charlist(name), String.to_charlist(full)}
      end

    :ok = :erl_tar.create(String.to_charlist(path), entries, [:compressed])
    File.rm_rf!(staging)
  end
end
