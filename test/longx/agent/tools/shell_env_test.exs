defmodule Longx.Agent.Tools.ShellEnvTest do
  use ExUnit.Case, async: true

  alias Longx.Agent.Tools.ShellEnv

  test "parses `env -0` output, tolerating the junk an interactive shell prints first" do
    out =
      "\e]7;file://host/home/x\a" <>
        "PATH=/a:/b\0HOME=/home/x\0MULTI=one\ntwo\0PWD=/tmp\0SHLVL=2\0_=/usr/bin/env\0LONGX_SECRET=x\0"

    env = ShellEnv.parse(out)
    assert env["PATH"] == "/a:/b"
    assert env["HOME"] == "/home/x"
    assert env["MULTI"] == "one\ntwo"
    refute Map.has_key?(env, "PWD")
    refute Map.has_key?(env, "SHLVL")
    refute Map.has_key?(env, "_")
    refute Map.has_key?(env, "LONGX_SECRET")
  end

  test "a snapshot of a real shell has PATH and HOME; the user's shell is preferred" do
    assert {:ok, env} = ShellEnv.snapshot("/bin/sh")
    assert is_binary(env["PATH"])
    assert env["HOME"] == System.get_env("HOME")
    assert env["TERM"] == "dumb"

    shell = ShellEnv.shell()
    assert File.exists?(shell)
    assert shell == (System.get_env("SHELL") || shell)
  end

  test "env/0 is cached for the BEAM and refreshable" do
    first = ShellEnv.env()
    assert first["PATH"]
    assert ShellEnv.env() == first
    assert {:ok, _} = ShellEnv.refresh()
  end
end
