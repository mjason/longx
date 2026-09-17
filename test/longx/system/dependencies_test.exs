defmodule Longx.System.DependenciesTest do
  use ExUnit.Case, async: false

  alias Longx.System.Dependencies

  setup do
    bin = Path.join(System.tmp_dir!(), "longx-deps-#{System.unique_integer([:positive])}")
    File.mkdir_p!(bin)
    on_exit(fn -> File.rm_rf!(bin) end)

    stub = fn name, body ->
      path = Path.join(bin, name)
      File.write!(path, "#!/bin/sh\n" <> body)
      File.chmod!(path, 0o755)
    end

    stub.("rg", "echo 'ripgrep 14.1.0'\necho 'features: +pcre2'\n")
    # the Debian spelling of fd
    stub.("fdfind", "echo 'fd 9.0.0'\n")
    # a tool that hangs on --version must not hang the check
    stub.("jq", "sleep 5\n")
    stub.("tree", "echo 'tree v2.1.1 (c) 1996' >&2\n")
    %{bin: bin}
  end

  test "every tool is looked up on the given PATH under each of its spellings, with its version",
       %{bin: bin} do
    report = Dependencies.check(path: bin, os: :linux)
    by = Map.new(report.tools, &{&1.name, &1})

    assert %{found: true, command: "rg", version: "14.1.0"} = by["ripgrep"]
    assert by["ripgrep"].path == Path.join(bin, "rg")
    assert %{found: true, command: "fdfind", version: "9.0.0"} = by["fd-find"]
    # found, but its version never came back in time
    assert %{found: true, version: nil} = by["jq"]
    # the version may be on stderr
    assert %{found: true, version: "2.1.1"} = by["tree"]
    assert %{found: false, path: nil, version: nil} = by["git"]

    assert Enum.map(report.tools, & &1.name) ==
             ~w(ripgrep fd-find fzf bat jq tree git gh git-delta)

    assert report.missing == 5
    assert report.os == "linux"
    # one command installs everything missing, for the platform
    assert report.install_command == "sudo apt install fzf bat git gh git-delta"
  end

  test "the install line follows the platform; nothing missing means no line", %{bin: bin} do
    assert Dependencies.check(path: bin, os: :darwin).install_command ==
             "brew install fzf bat git gh git-delta"

    assert Dependencies.check(path: bin, os: :windows).install_command =~
             "winget install --id junegunn.fzf"

    for tool <- ~w(fzf bat git gh delta) do
      path = Path.join(bin, tool)
      File.write!(path, "#!/bin/sh\necho '#{tool} 1.2.3'\n")
      File.chmod!(path, 0o755)
    end

    report = Dependencies.check(path: bin, os: :linux)
    assert report.missing == 0
    assert report.install_command == nil
    assert Map.new(report.tools, &{&1.name, &1.version})["git-delta"] == "1.2.3"
  end

  test "the report is cached and a forced check runs again", %{bin: bin} do
    Dependencies.forget()
    first = Dependencies.report(path: bin, os: :linux)
    File.write!(Path.join(bin, "fzf"), "#!/bin/sh\necho 'fzf 0.50'\n")
    File.chmod!(Path.join(bin, "fzf"), 0o755)
    assert Dependencies.report(path: bin, os: :linux) == first
    assert Dependencies.report(path: bin, os: :linux, force: true).missing == first.missing - 1
    Dependencies.forget()
  end
end
