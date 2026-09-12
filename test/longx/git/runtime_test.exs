defmodule Longx.Git.RuntimeTest do
  use ExUnit.Case, async: true

  alias Longx.Git.Runtime

  describe "pinned release" do
    test "version, tag and asset naming (dugite-native)" do
      assert Runtime.version() == "2.53.0"
      assert Runtime.release_tag() == "v2.53.0-4"
      assert Runtime.asset_name("ubuntu-x64") == "dugite-native-v2.53.0-4098283-ubuntu-x64.tar.gz"

      assert Runtime.asset_url("ubuntu-x64") ==
               "https://github.com/desktop/dugite-native/releases/download/v2.53.0-4/dugite-native-v2.53.0-4098283-ubuntu-x64.tar.gz"
    end

    test "our platforms map onto dugite's names" do
      assert Runtime.target({:linux, :x86_64}) == "ubuntu-x64"
      assert Runtime.target({:linux, :aarch64}) == "ubuntu-arm64"
      assert Runtime.target({:darwin, :x86_64}) == "macOS-x64"
      assert Runtime.target({:darwin, :aarch64}) == "macOS-arm64"
      assert Runtime.target({:windows, :x86_64}) == "windows-x64"
      assert Runtime.target({:windows, :aarch64}) == "windows-arm64"
    end

    test "every supported target has a pinned sha256" do
      for target <- ~w(ubuntu-x64 ubuntu-arm64 macOS-x64 macOS-arm64 windows-x64 windows-arm64) do
        assert {:ok, sha} = Runtime.sha256(target)
        assert sha =~ ~r/^[0-9a-f]{64}$/
      end

      assert {:error, :unsupported_target} = Runtime.sha256("plan9")
    end
  end

  describe "layout & environment (dugite conventions)" do
    test "unix: bin/git, libexec/git-core, system gitconfig and templates from the bundle" do
      root = "/opt/longx/git/ubuntu-x64"

      assert Runtime.executable_path(root, {:linux, :x86_64}) ==
               "/opt/longx/git/ubuntu-x64/bin/git"

      env = Map.new(Runtime.env(root, {:linux, :x86_64}))

      assert env["GIT_EXEC_PATH"] == "/opt/longx/git/ubuntu-x64/libexec/git-core"
      assert env["GIT_CONFIG_SYSTEM"] == "/opt/longx/git/ubuntu-x64/etc/gitconfig"
      assert env["GIT_TEMPLATE_DIR"] == "/opt/longx/git/ubuntu-x64/share/git-core/templates"
      # linux only: relocated prefix and the bundled CA bundle
      assert env["PREFIX"] == root
      assert env["GIT_SSL_CAINFO"] == "/opt/longx/git/ubuntu-x64/ssl/cacert.pem"
    end

    test "macOS: same as linux minus PREFIX / CA bundle" do
      env = Map.new(Runtime.env("/r", {:darwin, :aarch64}))
      assert env["GIT_EXEC_PATH"] == "/r/libexec/git-core"
      refute Map.has_key?(env, "PREFIX")
      refute Map.has_key?(env, "GIT_SSL_CAINFO")
    end

    test "windows: cmd/git.exe, mingw64 exec path, PATH prepended" do
      root = "C:/longx/git/windows-x64"

      assert Runtime.executable_path(root, {:windows, :x86_64}) ==
               "C:/longx/git/windows-x64/cmd/git.exe"

      env = Map.new(Runtime.env(root, {:windows, :x86_64}, %{"PATH" => "C:/Windows"}))

      assert env["GIT_EXEC_PATH"] == "C:/longx/git/windows-x64/mingw64/libexec/git-core"

      assert env["PATH"] ==
               "C:/longx/git/windows-x64/mingw64/bin;C:/longx/git/windows-x64/mingw64/usr/bin;C:/Windows"

      refute Map.has_key?(env, "GIT_CONFIG_SYSTEM")
    end

    test "every invocation is non-interactive and parseable" do
      env = Map.new(Runtime.env("/r", {:linux, :x86_64}))
      assert env["GIT_TERMINAL_PROMPT"] == "0"
      assert env["LC_ALL"] == "C"
    end
  end

  describe "install/2 from a local archive" do
    setup do
      root = Path.join(System.tmp_dir!(), "longx-git-rt-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)

      archive = Path.join(root, "git.tar.gz")
      build_fake_bundle(archive)

      sha =
        archive |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

      %{root: root, archive: archive, sha: sha, dir: Path.join(root, "install")}
    end

    test "verifies, extracts, and the executable is found", ctx do
      assert {:ok, exe} =
               Runtime.install("ubuntu-x64",
                 source: {:file, ctx.archive},
                 sha256: ctx.sha,
                 dir: ctx.dir
               )

      assert exe == Path.join([ctx.dir, "ubuntu-x64", "bin", "git"])
      assert File.exists?(exe)
      assert File.exists?(Path.join([ctx.dir, "ubuntu-x64", "libexec", "git-core", "git-lfs"]))
      assert Runtime.installed?("ubuntu-x64", dir: ctx.dir)
      assert {:ok, ^exe} = Runtime.executable("ubuntu-x64", dir: ctx.dir)
    end

    test "rejects a bundle without a git binary", ctx do
      bad = Path.join(ctx.root, "bad.tar.gz")
      build_fake_bundle(bad, with_git: false)
      sha = bad |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

      assert {:error, {:extract_failed, {:missing_executable, _}}} =
               Runtime.install("ubuntu-x64", source: {:file, bad}, sha256: sha, dir: ctx.dir)

      refute Runtime.installed?("ubuntu-x64", dir: ctx.dir)
    end

    test "checksum mismatch leaves nothing behind", ctx do
      assert {:error, {:checksum_mismatch, _}} =
               Runtime.install("ubuntu-x64",
                 source: {:file, ctx.archive},
                 sha256: String.duplicate("0", 64),
                 dir: ctx.dir
               )

      refute File.exists?(Path.join(ctx.dir, "ubuntu-x64"))
    end

    test "LONGX_GIT overrides the resolved executable", ctx do
      System.put_env("LONGX_GIT", "/usr/bin/git")
      on_exit(fn -> System.delete_env("LONGX_GIT") end)
      assert {:ok, "/usr/bin/git"} = Runtime.executable("ubuntu-x64", dir: ctx.dir)
    end
  end

  # dugite-native unix layout: files at the archive root (./bin/git, ./libexec/git-core/...)
  defp build_fake_bundle(path, opts \\ []) do
    staging = Path.join(Path.dirname(path), "staging-#{System.unique_integer([:positive])}")

    files =
      [
        {"libexec/git-core/git-lfs", "#!/bin/sh\n", 0o755},
        {"etc/gitconfig", "[core]\n", 0o644},
        {"share/git-core/templates/description", "x", 0o644},
        {"ssl/cacert.pem", "x", 0o644}
      ] ++
        if(Keyword.get(opts, :with_git, true),
          do: [{"bin/git", "#!/bin/sh\necho git version 2.53.0\n", 0o755}],
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
          do: {String.to_charlist("./" <> name), String.to_charlist(Path.join(staging, name))}

    :ok = :erl_tar.create(String.to_charlist(path), entries, [:compressed])
    File.rm_rf!(staging)
  end
end
