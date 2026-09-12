defmodule Mix.Tasks.Git.Fetch do
  @shortdoc "Downloads the bundled git (dugite-native) into priv/git"

  @moduledoc """
  Downloads, checksum-verifies and unpacks the pinned portable git + git-lfs
  (see `Longx.Git.Runtime`) into `priv/git/<target>/`.

      mix git.fetch                 # current platform
      mix git.fetch --target windows-x64
      mix git.fetch --force

  Part of `mix setup`; run before `mix release` in CI.
  """

  use Mix.Task

  alias Longx.Git.Runtime

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [target: :string, force: :boolean])
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:req)

    target = opts[:target] || Runtime.current_target()

    cond do
      not Keyword.get(opts, :force, false) and Runtime.installed?(target) ->
        Mix.shell().info("git #{Runtime.version()} (#{target}) already installed")

      true ->
        Mix.shell().info("Fetching #{Runtime.asset_url(target)}")

        case Runtime.install(target) do
          {:ok, exe} -> Mix.shell().info("Installed #{exe}")
          {:error, reason} -> Mix.raise("git.fetch failed: #{inspect(reason, pretty: true)}")
        end
    end
  end
end
