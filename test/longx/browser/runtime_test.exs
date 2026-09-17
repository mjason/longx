defmodule Longx.Browser.RuntimeTest do
  @moduledoc """
  The obscura (headless browser) release pin: per-target archives (tar.gz,
  zip on Windows), installed into the data directory under
  `<dir>/<version>/<target>/` from a local archive with the same
  verify/extract/replace path the real download takes.
  """
  use ExUnit.Case, async: true

  alias Longx.Browser.Runtime

  describe "release pin" do
    test "version, tag and asset naming (obscura's <arch>-<os> names)" do
      assert Runtime.version() == "0.2.2"
      assert Runtime.release_tag() == "v0.2.2"
      assert Runtime.asset_name("x86_64-linux") == "obscura-x86_64-linux.tar.gz"
      assert Runtime.asset_name("x86_64-windows") == "obscura-x86_64-windows.zip"

      assert Runtime.asset_url("aarch64-macos") ==
               "https://github.com/h4ckf0r0day/obscura/releases/download/v0.2.2/obscura-aarch64-macos.tar.gz"
    end

    test "our platforms map onto obscura's targets; windows arm64 is not built upstream" do
      assert Runtime.target({:linux, :x86_64}) == "x86_64-linux"
      assert Runtime.target({:linux, :aarch64}) == "aarch64-linux"
      assert Runtime.target({:darwin, :x86_64}) == "x86_64-macos"
      assert Runtime.target({:darwin, :aarch64}) == "aarch64-macos"
      assert Runtime.target({:windows, :x86_64}) == "x86_64-windows"
      assert Runtime.target({:windows, :aarch64}) == nil
    end

    test "every supported target has a pinned sha256" do
      for target <- ~w(x86_64-linux aarch64-linux x86_64-macos aarch64-macos x86_64-windows) do
        assert {:ok, sha} = Runtime.sha256(target)
        assert sha =~ ~r/^[0-9a-f]{64}$/
      end

      assert {:error, :unsupported_target} = Runtime.sha256("aarch64-windows")
    end
  end

  describe "layout" do
    test "the binary sits at the archive root; windows has .exe" do
      assert Runtime.executable_path("/r", {:linux, :x86_64}) == "/r/obscura"
      assert Runtime.executable_path("/r", {:windows, :x86_64}) == "/r/obscura.exe"
    end
  end

  describe "install/2 from a local archive" do
    setup do
      root =
        Path.join(System.tmp_dir!(), "longx-obscura-rt-#{System.unique_integer([:positive])}")

      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      %{root: root, dir: Path.join(root, "install")}
    end

    test "tar.gz: verifies, extracts, and the executable is found", ctx do
      archive = Path.join(ctx.root, "obscura.tar.gz")
      build_fake_tarball(archive)

      assert {:ok, exe} =
               Runtime.install("x86_64-linux",
                 source: {:file, archive},
                 sha256: sha(archive),
                 dir: ctx.dir
               )

      assert exe == Path.join([ctx.dir, "0.2.2", "x86_64-linux", "obscura"])
      assert File.exists?(exe)
      assert File.exists?(Path.join([ctx.dir, "0.2.2", "x86_64-linux", "obscura-worker"]))
      assert Runtime.installed?("x86_64-linux", dir: ctx.dir)
      assert {:ok, ^exe} = Runtime.executable("x86_64-linux", dir: ctx.dir)
    end

    test "zip (windows): the same path through Longx.Bundle", ctx do
      archive = Path.join(ctx.root, "obscura.zip")
      build_fake_zip(archive)

      assert {:ok, exe} =
               Runtime.install("x86_64-windows",
                 source: {:file, archive},
                 sha256: sha(archive),
                 dir: ctx.dir
               )

      assert exe == Path.join([ctx.dir, "0.2.2", "x86_64-windows", "obscura.exe"])
      assert File.exists?(exe)
    end

    test "an archive without the binary is rejected", ctx do
      bad = Path.join(ctx.root, "bad.tar.gz")
      build_fake_tarball(bad, with_binary: false)

      assert {:error, {:extract_failed, {:missing_executable, _}}} =
               Runtime.install("x86_64-linux",
                 source: {:file, bad},
                 sha256: sha(bad),
                 dir: ctx.dir
               )

      refute Runtime.installed?("x86_64-linux", dir: ctx.dir)
    end

    test "the progress callback sees the bytes; the stage callback the steps", ctx do
      archive = Path.join(ctx.root, "obscura.tar.gz")
      build_fake_tarball(archive)
      test = self()

      assert {:ok, _} =
               Runtime.install("x86_64-linux",
                 source: {:file, archive},
                 sha256: sha(archive),
                 dir: ctx.dir,
                 on_stage: fn stage -> send(test, {:stage, stage}) end
               )

      assert_receive {:stage, :verifying}
      assert_receive {:stage, :extracting}
    end

    test "the directory comes from the configuration", _ctx do
      previous = Application.get_env(:longx, Longx.Browser, [])
      Application.put_env(:longx, Longx.Browser, Keyword.put(previous, :dir, "/srv/x/obscura"))
      on_exit(fn -> Application.put_env(:longx, Longx.Browser, previous) end)
      assert Runtime.dir() == "/srv/x/obscura"
    end

    test "LONGX_OBSCURA overrides the resolved executable", ctx do
      System.put_env("LONGX_OBSCURA", "/opt/obscura/obscura")
      on_exit(fn -> System.delete_env("LONGX_OBSCURA") end)
      assert {:ok, "/opt/obscura/obscura"} = Runtime.executable("x86_64-linux", dir: ctx.dir)
    end
  end

  defp sha(path),
    do: path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  defp build_fake_tarball(path, opts \\ []) do
    staging = Path.join(Path.dirname(path), "staging-#{System.unique_integer([:positive])}")

    files =
      [{"obscura-worker", "#!/bin/sh\n", 0o755}] ++
        if(Keyword.get(opts, :with_binary, true),
          do: [{"obscura", "#!/bin/sh\necho obscura 0.2.2\n", 0o755}],
          else: []
        )

    for {name, content, mode} <- files do
      full = Path.join(staging, name)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
      File.chmod!(full, mode)
    end

    entries =
      for {name, _, _} <- files,
          do: {String.to_charlist(name), String.to_charlist(Path.join(staging, name))}

    :ok = :erl_tar.create(String.to_charlist(path), entries, [:compressed])
    File.rm_rf!(staging)
  end

  defp build_fake_zip(path) do
    {:ok, _} =
      :zip.create(
        String.to_charlist(path),
        [{~c"obscura.exe", "MZ fake"}, {~c"obscura-worker.exe", "MZ fake"}]
      )
  end
end
