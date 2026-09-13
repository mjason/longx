defmodule Mix.Tasks.Obscura.Fetch do
  @shortdoc "Downloads the bundled obscura (headless browser) into priv/obscura"

  @moduledoc """
  Downloads, checksum-verifies and unpacks the pinned obscura release (see
  `Longx.Browser.Runtime`) into `priv/obscura/<target>/`. Optional: without
  it `web.run`'s `open` falls back to a plain fetch and the browser tools are
  unavailable.

      mix obscura.fetch                 # current platform
      mix obscura.fetch --target x86_64-windows
      mix obscura.fetch --force

  Part of `mix setup`; run before `mix release` in CI.
  """

  use Mix.Task

  alias Longx.Browser.Runtime

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [target: :string, force: :boolean])
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:req)

    target = opts[:target] || Runtime.current_target()

    cond do
      is_nil(target) ->
        Mix.shell().info("obscura has no build for this platform; skipping")

      not Keyword.get(opts, :force, false) and Runtime.installed?(target) ->
        Mix.shell().info("obscura #{Runtime.version()} (#{target}) already installed")

      true ->
        Mix.shell().info("Fetching #{Runtime.asset_url(target)}")

        case Runtime.install(target) do
          {:ok, exe} -> Mix.shell().info("Installed #{exe}")
          {:error, reason} -> Mix.raise("obscura.fetch failed: #{inspect(reason, pretty: true)}")
        end
    end
  end
end
