defmodule LongxWeb.ShellEnvironmentBrowserTest do
  @moduledoc "Real settings UI → GraphQL → shell snapshot, using synthetic startup files only."
  use Longx.DataCase, async: false
  alias Longx.Agent.Tools.ShellEnv
  @moduletag :integration
  @moduletag timeout: 120_000

  test "refresh, pending, failure preservation and retry in desktop and mobile settings" do
    %{shell: shell} = Longx.Test.ShellEnvFixture.setup()
    original = ShellEnv.env_list()
    vite = Application.get_env(:longx, LongxWeb.Vite)
    key = {LongxWeb.Vite, :manifest}
    cached = :persistent_term.get(key, :not_cached)

    Application.put_env(:longx, LongxWeb.Vite,
      manifest: {:priv, "static/assets/.vite/manifest.json"},
      entries: ["js/index.tsx"],
      dev_server: nil
    )

    :persistent_term.erase(key)

    on_exit(fn ->
      Application.put_env(:longx, LongxWeb.Vite, vite)
      :persistent_term.erase(key)
      if cached != :not_cached, do: :persistent_term.put(key, cached)
    end)

    server = start_supervised!({Bandit, plug: LongxWeb.Endpoint, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    {out, code} =
      System.cmd(
        "node",
        ["assets/scripts/test-shell-environment-live.mjs", "http://localhost:#{port}", shell],
        stderr_to_stdout: true
      )

    assert code == 0, out
    assert out =~ "shell environment browser 1280px passed"
    assert out =~ "shell environment browser 390px passed"
    assert Map.new(original)["SHELL_REFRESH_VALUE"] == "first"
    assert ShellEnv.env()["SHELL_REFRESH_VALUE"] == "ready-390"
    assert String.starts_with?(ShellEnv.env()["PATH"], "/fixture-extra:")
    assert Longx.Agent.Definition.Settings.global().command_shell == "auto"
  end
end
