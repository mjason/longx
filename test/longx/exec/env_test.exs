defmodule Longx.Exec.EnvTest do
  use ExUnit.Case, async: true

  alias Longx.Exec.Env

  @host %{
    "PATH" => "/usr/bin",
    "HOME" => "/home/mj",
    "USER" => "mj",
    "EDITOR" => "vim",
    "DEEPSEEK_API_KEY" => "sk-x",
    "MY_SECRET_THING" => "s",
    "GITHUB_TOKEN" => "t",
    "LONGX_GATEWAY_TOKEN" => "g",
    "LONGX_CLOAK_KEY" => "c",
    "OPENAI_IDENTITY_TOKEN_FILE" => "/x",
    "NODE_REPL_AUTH_TOKEN" => "n"
  }

  defp policy(over \\ %{}) do
    Map.merge(
      %{
        "inherit" => "all",
        "ignoreDefaultExcludes" => false,
        "exclude" => [],
        "set" => %{},
        "includeOnly" => []
      },
      over
    )
  end

  test "inherit all keeps the host environment minus secrets-looking names, then overlays codex's env" do
    env = Env.build(@host, policy(), %{"CODEX_CI" => "1", "PATH" => "/codex/bin:/usr/bin"})

    assert env["EDITOR"] == "vim"
    assert env["HOME"] == "/home/mj"
    assert env["PATH"] == "/codex/bin:/usr/bin"
    assert env["CODEX_CI"] == "1"
    refute Map.has_key?(env, "DEEPSEEK_API_KEY")
    refute Map.has_key?(env, "MY_SECRET_THING")
    refute Map.has_key?(env, "GITHUB_TOKEN")
  end

  test "Longx's own secrets and codex's non-inheritable variables never reach a command, whatever the policy says" do
    env = Env.build(@host, policy(%{"ignoreDefaultExcludes" => true}), %{})

    for name <-
          ~w(LONGX_GATEWAY_TOKEN LONGX_CLOAK_KEY OPENAI_IDENTITY_TOKEN_FILE NODE_REPL_AUTH_TOKEN DEEPSEEK_API_KEY) do
      refute Map.has_key?(env, name), name
    end

    # ignoreDefaultExcludes only lifts the pattern rule for names that are not secrets by our book
    assert env["EDITOR"] == "vim"
  end

  test "tool_bin: Longx's own tool directory (codex's apply_patch alias) leads PATH whatever the policy says" do
    assert Env.build(@host, policy(), %{}, tool_bin: "/data/codex_home/bin")["PATH"] ==
             "/data/codex_home/bin:" <> @host["PATH"]

    assert Env.build(@host, %{"inherit" => "none"}, %{}, tool_bin: "/data/codex_home/bin")["PATH"] ==
             "/data/codex_home/bin"

    # codex's overlay PATH, when it sends one, still comes after it
    assert Env.build(@host, policy(), %{"PATH" => "/codex/bin"}, tool_bin: "/t")["PATH"] ==
             "/t:/codex/bin"

    refute Env.build(@host, policy(), %{}, tool_bin: nil)["PATH"] =~ "codex_home"
  end

  test "inherit core keeps only the core variables" do
    env = Env.build(@host, policy(%{"inherit" => "core"}), %{})
    assert Map.keys(env) |> Enum.sort() == ~w(HOME PATH USER)
  end

  test "inherit none starts empty; set and the overlay still apply" do
    env =
      Env.build(@host, policy(%{"inherit" => "none", "set" => %{"FOO" => "1"}}), %{"BAR" => "2"})

    assert env == %{"FOO" => "1", "BAR" => "2"}
  end

  test "exclude and includeOnly are case-insensitive globs" do
    env = Env.build(@host, policy(%{"exclude" => ["edit*"]}), %{})
    refute Map.has_key?(env, "EDITOR")

    env = Env.build(@host, policy(%{"includeOnly" => ["path", "H?ME"]}), %{})
    assert Map.keys(env) |> Enum.sort() == ~w(HOME PATH)
  end

  test "set overrides an inherited value" do
    env = Env.build(@host, policy(%{"set" => %{"HOME" => "/tmp/h"}}), %{})
    assert env["HOME"] == "/tmp/h"
  end

  test "no policy: exactly what codex sent (codex's own executor does the same), secrets still out" do
    env = Env.build(@host, nil, %{"A" => "b", "NODE_REPL_AUTH_TOKEN" => "n"})
    assert env == %{"A" => "b"}
  end
end
