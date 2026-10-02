defmodule Longx.Computer.Runtime do
  @moduledoc """
  The local CUA Driver dependency. Releases are pinned and checksummed, installed
  into Longx's data directory, never through upstream shell installers.

  The complete macOS distribution includes the signed CuaDriver.app required
  for TCC attribution. Installing it does not start a daemon or grant desktop
  permissions. Computer tools and the HTTP MCP connection are separate work.
  """

  alias Longx.Platform

  @version "0.32.0"
  @base_url "https://github.com/trycua/cua/releases/download/cua-driver-rs-v#{@version}"
  @releases %{
    "darwin-arm64" =>
      {"31f278f38015616a02142ccbb396721897cee4892927db103a31b297f60035a9", 74_965_063},
    "darwin-x86_64" =>
      {"0322e9316d81fbe34cbe8efe2eae83a32cf4dd86b9f34639cc0a4b3a6ed74868", 74_965_069},
    "linux-arm64" =>
      {"262439491f2fa9b718ba37bee3838fff4ad53c77a32f4a73aaf243bad3cd794c", 34_132_737},
    "linux-x86_64" =>
      {"998e63452c38b76a682da2d07f4bb24f0c1663d76c861a5dc0c345a7ead1f889", 34_413_123},
    "windows-arm64" =>
      {"51f5723a6734afb7125c92fe05835bb815f7c37b75e2332dd48ae184ddb0a9f8", 29_105_396},
    "windows-x86_64" =>
      {"6d70b45c8c901db773010dd720c8bb9d58c59bb301e9891c58ca1d3860e75652", 30_885_377}
  }

  def version, do: @version

  def target({os, arch}) when os in [:darwin, :linux, :windows] and arch in [:aarch64, :x86_64],
    do: "#{os}-#{if arch == :aarch64, do: "arm64", else: "x86_64"}"

  def target(_), do: nil
  def current_target, do: target(Platform.current())

  def dir, do: config(:dir) || Path.expand("data/cua-driver")
  def config(key), do: :longx |> Application.get_env(Longx.Computer, []) |> Keyword.get(key)
  def root(base, target), do: Path.join([base, @version, target])
  def package_name(target, version \\ @version), do: "cua-driver-rs-#{version}-#{target}"

  def asset_name(target),
    do:
      package_name(target) <>
        if(String.starts_with?(target, "windows-"), do: ".zip", else: ".tar.gz")

  def asset_url(target), do: "#{@base_url}/#{asset_name(target)}"
  def sha256(target), do: elem(Map.fetch!(@releases, target), 0)
  def download_size(nil), do: nil
  def download_size(target), do: elem(Map.fetch!(@releases, target), 1)

  def executable_path(base, target, version \\ @version) do
    name = if String.starts_with?(target, "windows-"), do: "cua-driver.exe", else: "cua-driver"
    Path.join([base, package_name(target, version), name])
  end

  def app_path(path, "darwin-" <> _), do: Path.join(Path.dirname(path), "CuaDriver.app")
  def app_path(_path, _target), do: nil

  # Like obscura, only explicitly configured or verified downloaded binaries
  # are selected; an arbitrary executable on PATH is not adopted.
  def resolve(target \\ current_target()) do
    override = System.get_env("LONGX_CUA_DRIVER")

    cond do
      is_binary(override) and override != "" ->
        if File.regular?(override),
          do: {:ok, :env, override, nil},
          else: {:error, :not_installed}

      is_nil(target) ->
        {:error, :not_installed}

      true ->
        case installed_versions(target) do
          [version | _] ->
            path = executable_path(Path.join([dir(), version, target]), target, version)
            {:ok, :downloaded, path, version}

          [] ->
            {:error, :not_installed}
        end
    end
  end

  def installed_versions(target) do
    case File.ls(dir()) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&match?({:ok, _}, Version.parse(&1)))
        |> Enum.filter(fn version ->
          path = executable_path(Path.join([dir(), version, target]), target, version)
          valid_layout?(path, target)
        end)
        |> Enum.sort({:desc, Version})

      _ ->
        []
    end
  end

  def installed?(target), do: @version in installed_versions(target)

  def install(target, opts \\ []) do
    dest = root(Keyword.get(opts, :dir, dir()), target)

    with :ok <-
           Longx.Bundle.install(
             source: Keyword.get(opts, :source, {:url, asset_url(target)}),
             sha256: Keyword.get(opts, :sha256, sha256(target)),
             archive_name: asset_name(target),
             dest: dest,
             progress: Keyword.get(opts, :progress),
             on_stage: Keyword.get(opts, :on_stage),
             verify: fn staging ->
               if valid_layout?(executable_path(staging, target), target),
                 do: :ok,
                 else: {:error, {:extract_failed, :missing_driver_or_app}}
             end
           ) do
      {:ok, executable_path(dest, target)}
    end
  end

  defp valid_layout?(path, target) do
    File.regular?(path) and
      case app_path(path, target) do
        nil -> true
        app -> File.regular?(Path.join(app, "Contents/MacOS/cua-driver"))
      end
  end
end
