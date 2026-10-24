defmodule Longx.Test.ShellEnvFixture do
  @moduledoc "A synthetic shell and isolated cache for shell-refresh tests; never reads real startup files."
  import ExUnit.Callbacks, only: [on_exit: 1]

  def setup do
    dir =
      Path.join(System.tmp_dir!(), "longx-shell-refresh-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    path = Path.join(dir, "shell")

    File.write!(path, """
    #!/bin/sh
    mode=$(/bin/cat "$0.state")
    printf '%s\\n' "$mode" >> "$0.calls"
    if [ -e "$0.block" ]; then
      : > "$0.started"
      while [ ! -e "$0.release" ]; do /bin/sleep 0.01; done
    fi
    if [ "$mode" = fail ]; then
      printf 'SHELL_REFRESH_SECRET=fixture-stderr-secret\\n' >&2
      exit 23
    fi
    printf 'PATH=/shell-refresh/%s:/usr/bin:/bin\\000SHELL_REFRESH_VALUE=%s\\000SHELL_REFRESH_SECRET=fixture-env-secret\\000' "$mode" "$mode"
    """)

    File.chmod!(path, 0o700)
    File.write!(path <> ".state", "first")
    previous_shell = System.get_env("SHELL")
    key = {Longx.Agent.Tools.ShellEnv, :env}
    previous_cache = :persistent_term.get(key, :not_cached)
    System.put_env("SHELL", path)
    :persistent_term.erase(key)
    Longx.Agent.Definition.Settings.put_global(%{command_shell: "auto", extra_path: ""})

    on_exit(fn ->
      if previous_shell,
        do: System.put_env("SHELL", previous_shell),
        else: System.delete_env("SHELL")

      if previous_cache == :not_cached,
        do: :persistent_term.erase(key),
        else: :persistent_term.put(key, previous_cache)

      Longx.Test.TmpDirs.rm_rf!(dir)
    end)

    %{shell: path}
  end
end
