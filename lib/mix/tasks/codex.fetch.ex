defmodule Mix.Tasks.Codex.Fetch do
  @shortdoc "Downloads the pinned codex-app-server release into priv/codex"

  @moduledoc """
  Downloads, checksum-verifies and unpacks the pinned `codex-app-server`
  package (see `Longx.Codex.Runtime`) into `priv/codex/<target>/`.

      mix codex.fetch                    # current platform
      mix codex.fetch --target x86_64-unknown-linux-musl
      mix codex.fetch --force            # re-download even if installed

  Run it before `mix release` in CI so the release ships the binary for the
  platform it is built on (or `--target` for the platform it will run on).
  Skips the download when the target is already installed.
  """

  use Mix.Task

  alias Longx.Codex.Runtime

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [target: :string, force: :boolean])
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:req)

    target = opts[:target] || Runtime.current_target()

    cond do
      not Keyword.get(opts, :force, false) and Runtime.installed?(target) ->
        Mix.shell().info("codex-app-server #{Runtime.version()} (#{target}) already installed")

      true ->
        Mix.shell().info("Fetching #{Runtime.asset_url(target)}")

        case Runtime.install(target) do
          {:ok, exe} -> Mix.shell().info("Installed #{exe}")
          {:error, reason} -> Mix.raise("codex.fetch failed: #{inspect(reason, pretty: true)}")
        end
    end
  end
end
