defmodule Longx.PlatformTest do
  use ExUnit.Case, async: true

  alias Longx.Platform

  describe "detect/2" do
    test "linux x86_64" do
      assert Platform.detect({:unix, :linux}, "x86_64-pc-linux-gnu") == {:linux, :x86_64}
    end

    test "linux aarch64 (musl toolchain string)" do
      assert Platform.detect({:unix, :linux}, "aarch64-alpine-linux-musl") == {:linux, :aarch64}
    end

    test "macOS arm64 / x86_64" do
      assert Platform.detect({:unix, :darwin}, "aarch64-apple-darwin23.4.0") ==
               {:darwin, :aarch64}

      assert Platform.detect({:unix, :darwin}, "x86_64-apple-darwin23.4.0") == {:darwin, :x86_64}
    end

    test "windows uses PROCESSOR_ARCHITECTURE since the ERTS string is win32" do
      assert Platform.detect({:win32, :nt}, "win32", %{"PROCESSOR_ARCHITECTURE" => "AMD64"}) ==
               {:windows, :x86_64}

      assert Platform.detect({:win32, :nt}, "win32", %{"PROCESSOR_ARCHITECTURE" => "ARM64"}) ==
               {:windows, :aarch64}
    end

    test "amd64/arm64 spellings normalise" do
      assert Platform.detect({:unix, :freebsd}, "amd64-portbld-freebsd14.0") ==
               {:freebsd, :x86_64}

      assert Platform.detect({:unix, :linux}, "arm64-unknown-linux-gnu") == {:linux, :aarch64}
    end
  end

  test "current/0 returns a known os/arch pair" do
    {os, arch} = Platform.current()
    assert os in [:linux, :darwin, :windows]
    assert arch in [:x86_64, :aarch64]
  end

  describe "rust_target/1" do
    test "maps to the triples used by openai/codex release assets" do
      assert Platform.rust_target({:linux, :x86_64}) == "x86_64-unknown-linux-musl"
      assert Platform.rust_target({:linux, :aarch64}) == "aarch64-unknown-linux-musl"
      assert Platform.rust_target({:darwin, :aarch64}) == "aarch64-apple-darwin"
      assert Platform.rust_target({:darwin, :x86_64}) == "x86_64-apple-darwin"
      assert Platform.rust_target({:windows, :x86_64}) == "x86_64-pc-windows-msvc"
      assert Platform.rust_target({:windows, :aarch64}) == "aarch64-pc-windows-msvc"
    end
  end

  describe "go_target/1" do
    test "maps to GOOS/GOARCH" do
      assert Platform.go_target({:linux, :x86_64}) == {"linux", "amd64"}
      assert Platform.go_target({:darwin, :aarch64}) == {"darwin", "arm64"}
      assert Platform.go_target({:windows, :x86_64}) == {"windows", "amd64"}
    end
  end

  test "exe_suffix/1" do
    assert Platform.exe_suffix({:windows, :x86_64}) == ".exe"
    assert Platform.exe_suffix({:linux, :x86_64}) == ""
  end
end
