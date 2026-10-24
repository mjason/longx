defmodule Longx.Agent.Tools.ShellEnvRefreshTest do
  use Longx.DataCase, async: false
  alias Longx.Agent.Tools.ShellEnv

  setup do
    Longx.Test.ShellEnvFixture.setup()
  end

  test "explicit refresh replaces the cache for subsequent commands, not prior environments", %{
    shell: shell
  } do
    original = ShellEnv.env_list()
    assert Map.new(original)["SHELL_REFRESH_VALUE"] == "first"
    File.write!(shell <> ".state", "second")
    assert ShellEnv.env()["SHELL_REFRESH_VALUE"] == "first"

    assert {:ok, %{shell: ^shell, refreshed_at: %DateTime{}}} =
             Longx.System.refresh_shell_environment()

    assert ShellEnv.env()["SHELL_REFRESH_VALUE"] == "second"
    assert String.contains?(ShellEnv.env()["PATH"], "/shell-refresh/second")

    for {env, expected} <- [{original, "first"}, {ShellEnv.env_list(), "second"}] do
      assert {:ok, %{status: 0, stdout: ^expected}} =
               Longx.Shim.run(["/bin/sh", "-c", "printf '%s' \"$SHELL_REFRESH_VALUE\""],
                 env: env,
                 env_clear: true
               )
    end
  end

  test "failure preserves the old snapshot and does not expose startup output", %{shell: shell} do
    assert ShellEnv.env()["SHELL_REFRESH_VALUE"] == "first"
    File.write!(shell <> ".state", "fail")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :snapshot_failed} = ShellEnv.refresh_for_settings()
      end)

    refute log =~ "fixture-stderr-secret"
    assert ShellEnv.env()["SHELL_REFRESH_VALUE"] == "first"
  end

  test "first explicit failure does not populate the cache with fallback", %{shell: shell} do
    File.write!(shell <> ".state", "fail")
    assert {:error, :snapshot_failed} = ShellEnv.refresh_for_settings()
    assert :persistent_term.get({ShellEnv, :env}, nil) == nil
  end

  test "concurrent cold reads capture once", %{shell: shell} do
    File.write!(shell <> ".block", "")
    first = Task.async(fn -> ShellEnv.env() end)
    await_file(shell <> ".started")
    caller = self()

    readers =
      for _ <- 1..4 do
        Task.async(fn ->
          send(caller, :reading_environment)
          ShellEnv.env()
        end)
      end

    for _ <- readers, do: assert_receive(:reading_environment)
    File.write!(shell <> ".release", "")

    for reader <- [first | readers],
        do: assert(Task.await(reader)["SHELL_REFRESH_VALUE"] == "first")

    assert File.read!(shell <> ".calls") == "first\n"
  end

  test "cache hits remain available while a refresh is blocked", %{shell: shell} do
    assert ShellEnv.env()["SHELL_REFRESH_VALUE"] == "first"
    File.write!(shell <> ".state", "second")
    File.write!(shell <> ".block", "")
    refresh = Task.async(fn -> ShellEnv.refresh_for_settings() end)
    await_file(shell <> ".started")
    hit = Task.async(fn -> ShellEnv.env() end)
    assert Task.await(hit, 1_000)["SHELL_REFRESH_VALUE"] == "first"
    File.write!(shell <> ".release", "")
    assert {:ok, _} = Task.await(refresh)
    assert ShellEnv.env()["SHELL_REFRESH_VALUE"] == "second"
  end

  test "an explicit refresh follows a blocked implicit capture", %{shell: shell} do
    File.write!(shell <> ".block", "")
    implicit = Task.async(fn -> ShellEnv.env() end)
    await_file(shell <> ".started")
    File.write!(shell <> ".state", "second")
    caller = self()

    explicit =
      Task.async(fn ->
        send(caller, :refreshing_environment)
        ShellEnv.refresh_for_settings()
      end)

    assert_receive :refreshing_environment
    File.write!(shell <> ".release", "")
    assert Task.await(implicit)["SHELL_REFRESH_VALUE"] == "first"
    assert {:ok, _} = Task.await(explicit)
    assert File.read!(shell <> ".calls") == "first\nsecond\n"
    assert ShellEnv.env()["SHELL_REFRESH_VALUE"] == "second"
  end

  test "first-use environment keeps its previous fallback behavior", %{shell: shell} do
    File.write!(shell <> ".state", "fail")

    ExUnit.CaptureLog.capture_log(fn ->
      assert is_binary(ShellEnv.env()["PATH"])
    end)
  end

  test "concurrent refreshes do not overwrite a newer capture with an older result", %{
    shell: shell
  } do
    File.write!(shell <> ".block", "")
    first = Task.async(fn -> ShellEnv.refresh_for_settings() end)
    await_file(shell <> ".started")
    File.write!(shell <> ".state", "second")
    caller = self()

    second =
      Task.async(fn ->
        send(caller, :refreshing_environment)
        ShellEnv.refresh_for_settings()
      end)

    assert_receive :refreshing_environment
    Process.sleep(50)
    assert File.read!(shell <> ".calls") == "first\n"
    File.write!(shell <> ".release", "")
    assert {:ok, _} = Task.await(first)
    assert {:ok, _} = Task.await(second)
    assert File.read!(shell <> ".calls") == "first\nsecond\n"
    assert ShellEnv.env()["SHELL_REFRESH_VALUE"] == "second"
  end

  defp await_file(path, attempts \\ 200)
  defp await_file(_path, 0), do: flunk("synthetic shell did not start")

  defp await_file(path, attempts) do
    unless File.exists?(path) do
      Process.sleep(10)
      await_file(path, attempts - 1)
    end
  end
end
