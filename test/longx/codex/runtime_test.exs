defmodule Longx.Codex.RuntimeTest do
  use ExUnit.Case, async: true

  alias Longx.Codex.Runtime

  @target "x86_64-unknown-linux-musl"

  describe "pinned release" do
    test "version and asset naming" do
      assert Runtime.version() == "0.154.0"
      assert Runtime.asset_name(@target) == "codex-app-server-package-#{@target}.tar.gz"

      assert Runtime.asset_url(@target) ==
               "https://github.com/openai/codex/releases/download/rust-v0.154.0/codex-app-server-package-#{@target}.tar.gz"
    end

    test "every supported platform has a pinned sha256" do
      for platform <- Runtime.supported_platforms() do
        target = Longx.Platform.rust_target(platform)
        assert {:ok, sha} = Runtime.sha256(target)
        assert sha =~ ~r/^[0-9a-f]{64}$/
      end

      assert {:error, :unsupported_target} = Runtime.sha256("mips-unknown-linux-gnu")
    end
  end

  describe "install/2 from a local archive" do
    setup do
      root = Path.join(System.tmp_dir!(), "longx-codex-rt-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)

      archive = Path.join(root, "pkg.tar.gz")
      build_fake_package(archive, @target)

      sha =
        archive |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

      %{root: root, archive: archive, sha: sha, install_dir: Path.join(root, "install")}
    end

    test "verifies the checksum, extracts, and reports the entrypoint", ctx do
      assert {:ok, exe} =
               Runtime.install(@target,
                 source: {:file, ctx.archive},
                 sha256: ctx.sha,
                 dir: ctx.install_dir
               )

      assert exe == Path.join([ctx.install_dir, @target, "bin", "codex-app-server"])
      assert File.exists?(exe)
      assert File.exists?(Path.join([ctx.install_dir, @target, "codex-resources", "bwrap"]))
      assert File.exists?(Path.join([ctx.install_dir, @target, "codex-package.json"]))
      # executable bit survives extraction
      assert Bitwise.band(File.stat!(exe).mode, 0o100) != 0
    end

    test "rejects a checksum mismatch and leaves nothing behind", ctx do
      bad = String.duplicate("0", 64)

      assert {:error, {:checksum_mismatch, %{expected: ^bad, actual: actual}}} =
               Runtime.install(@target,
                 source: {:file, ctx.archive},
                 sha256: bad,
                 dir: ctx.install_dir
               )

      assert actual == ctx.sha
      refute File.exists?(Path.join(ctx.install_dir, @target))
    end

    test "rejects an archive whose codex-package.json disagrees with the pin", ctx do
      archive = Path.join(ctx.root, "wrong.tar.gz")
      build_fake_package(archive, @target, version: "0.1.0")

      sha =
        archive |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

      assert {:error, {:version_mismatch, %{expected: "0.154.0", actual: "0.1.0"}}} =
               Runtime.install(@target,
                 source: {:file, archive},
                 sha256: sha,
                 dir: ctx.install_dir
               )

      refute File.exists?(Path.join(ctx.install_dir, @target))
    end

    test "installed?/2 and executable/2 see the result", ctx do
      refute Runtime.installed?(@target, dir: ctx.install_dir)
      assert {:error, :not_installed} = Runtime.executable(@target, dir: ctx.install_dir)

      {:ok, exe} =
        Runtime.install(@target,
          source: {:file, ctx.archive},
          sha256: ctx.sha,
          dir: ctx.install_dir
        )

      assert Runtime.installed?(@target, dir: ctx.install_dir)
      assert {:ok, ^exe} = Runtime.executable(@target, dir: ctx.install_dir)
    end

    test "an env override wins over the install dir", ctx do
      System.put_env("LONGX_CODEX_APP_SERVER", ctx.archive)
      on_exit(fn -> System.delete_env("LONGX_CODEX_APP_SERVER") end)

      assert {:ok, exe} = Runtime.executable(@target, dir: ctx.install_dir)
      assert exe == ctx.archive
    end
  end

  # Mirrors the layout of codex-app-server-package-<target>.tar.gz
  defp build_fake_package(path, target, opts \\ []) do
    version = Keyword.get(opts, :version, Runtime.version())

    manifest =
      Jason.encode!(%{
        layoutVersion: 1,
        version: version,
        target: target,
        variant: "codex-app-server",
        entrypoint: "bin/codex-app-server",
        resourcesDir: "codex-resources",
        pathDir: "codex-path"
      })

    files = [
      {~c"codex-package.json", manifest, 0o644},
      {~c"bin/codex-app-server", "#!/bin/sh\necho fake\n", 0o755},
      {~c"codex-resources/bwrap", "#!/bin/sh\n", 0o755},
      {~c"codex-path/rg", "#!/bin/sh\n", 0o755}
    ]

    staging = Path.join(Path.dirname(path), "staging-#{System.unique_integer([:positive])}")

    for {name, content, mode} <- files do
      full = Path.join(staging, to_string(name))
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
      File.chmod!(full, mode)
    end

    entries =
      for {name, _, _} <- files,
          do: {name, String.to_charlist(Path.join(staging, to_string(name)))}

    :ok = :erl_tar.create(String.to_charlist(path), entries, [:compressed])
    File.rm_rf!(staging)
  end
end
