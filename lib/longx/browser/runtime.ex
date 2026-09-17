defmodule Longx.Browser.Runtime do
  @moduledoc """
  **obscura** — a headless browser (Rust + embedded V8, Chrome DevTools
  Protocol) that renders JavaScript pages without Chromium — is what the
  agent's `web_fetch` runs. It is not bundled: `Longx.Browser.Installer`
  downloads it on first need into the data directory,
  `<dir>/<version>/<target>/` (`config :longx, Longx.Browser, dir:` — dev
  `data/obscura`, prod `$LONGX_DATA_DIR/obscura`).

  Pinned to one upstream release with a per-target sha256 (upstream publishes
  no checksums, so they were computed once when pinning and are verified on
  every download). Archives hold `obscura` and `obscura-worker` at the root
  (both needed, same directory); Linux builds want glibc ≥ 2.35. The default
  variant (with rendering, no stealth) is the one installed.

  `LONGX_OBSCURA=/path/to/obscura` overrides the resolved binary.
  """

  alias Longx.Platform

  @version "0.2.2"
  @release_tag "v0.2.2"
  @base_url "https://github.com/h4ckf0r0day/obscura/releases/download/#{@release_tag}"
  @env_override "LONGX_OBSCURA"

  # computed by us at pin time (sha256sum over the release assets)
  @sha256 %{
    "x86_64-linux" => "9e5d9d081909ea983bc8c94999bb3d411fd6b74a9788504295b7e25f84310505",
    "aarch64-linux" => "fd422a9bc0cb38047d270c2d0ee393df5c4d54fa9d0130d39917e858cd7020ae",
    "x86_64-macos" => "a60ad71a9e8d6ab1b8f51d3ddca8e043178b9c03c704719d6e717f77ead3ee43",
    "aarch64-macos" => "607471654d0c23799abd3bf45d1f4afd314a11fdbe1ee376e29018f32a2dfab9",
    "x86_64-windows" => "db5a3c951f7172eb8f25e6d71bd7120c7128f70f6daed55a6cc4caaabe1674d6"
  }

  @type target :: String.t()

  @spec version() :: String.t()
  def version, do: @version

  @spec release_tag() :: String.t()
  def release_tag, do: @release_tag

  @spec asset_name(target) :: String.t()
  def asset_name("x86_64-windows" = target), do: "obscura-#{target}.zip"
  def asset_name(target), do: "obscura-#{target}.tar.gz"

  @spec asset_url(target) :: String.t()
  def asset_url(target), do: "#{@base_url}/#{asset_name(target)}"

  @spec sha256(target) :: {:ok, String.t()} | {:error, :unsupported_target}
  def sha256(target) do
    case Map.fetch(@sha256, target) do
      {:ok, sha} -> {:ok, sha}
      :error -> {:error, :unsupported_target}
    end
  end

  @doc "obscura's name for a platform; nil where upstream builds nothing (windows arm64)."
  @spec target(Platform.t()) :: target | nil
  def target({:linux, :x86_64}), do: "x86_64-linux"
  def target({:linux, :aarch64}), do: "aarch64-linux"
  def target({:darwin, :x86_64}), do: "x86_64-macos"
  def target({:darwin, :aarch64}), do: "aarch64-macos"
  def target({:windows, :x86_64}), do: "x86_64-windows"
  def target({:windows, :aarch64}), do: nil

  @spec current_target() :: target | nil
  def current_target, do: target(Platform.current())

  @doc "Where releases are installed (`config :longx, Longx.Browser, dir:`)."
  @spec dir() :: Path.t()
  def dir do
    :longx
    |> Application.get_env(Longx.Browser, [])
    |> Keyword.get(:dir) || Path.expand("data/obscura")
  end

  @doc "The directory one target's release lives in under `dir`."
  @spec root(Path.t(), target) :: Path.t()
  def root(dir, target), do: Path.join([dir, @version, target])

  @spec executable_path(Path.t(), Platform.t()) :: Path.t()
  def executable_path(root, {:windows, _}), do: Path.join(root, "obscura.exe")
  def executable_path(root, _platform), do: Path.join(root, "obscura")

  ## Resolution

  @doc "Path to the installed obscura for `target`, honouring `LONGX_OBSCURA`."
  @spec executable(target | nil, keyword) :: {:ok, Path.t()} | {:error, :not_installed}
  def executable(target \\ current_target(), opts \\ []) do
    case System.get_env(@env_override) do
      path when is_binary(path) and path != "" ->
        {:ok, path}

      _ when is_nil(target) ->
        {:error, :not_installed}

      _ ->
        path = executable_path(root(dir(opts), target), platform_of(target))
        if File.regular?(path), do: {:ok, path}, else: {:error, :not_installed}
    end
  end

  @spec installed?(target | nil, keyword) :: boolean
  def installed?(target \\ current_target(), opts \\ [])
  def installed?(nil, _opts), do: false

  def installed?(target, opts),
    do: File.regular?(executable_path(root(dir(opts), target), platform_of(target)))

  @doc """
  Downloads (or copies), verifies and unpacks the archive for `target`; see
  `Longx.Bundle.install/1`. Options: `source:`, `sha256:`, `dir:`,
  `progress:` (`fn {received, total} -> … end` while downloading),
  `on_stage:` (`fn :verifying | :extracting -> … end`).
  """
  @spec install(target, keyword) :: {:ok, Path.t()} | {:error, term}
  def install(target, opts \\ []) do
    root = root(dir(opts), target)
    platform = platform_of(target)

    with {:ok, expected} <- expected_sha(target, opts),
         :ok <-
           Longx.Bundle.install(
             source: Keyword.get(opts, :source, {:url, asset_url(target)}),
             sha256: expected,
             dest: root,
             archive_name: asset_name(target),
             verify: &verify_layout(&1, platform),
             progress: Keyword.get(opts, :progress),
             on_stage: Keyword.get(opts, :on_stage)
           ) do
      {:ok, executable_path(root, platform)}
    end
  end

  defp expected_sha(target, opts) do
    case Keyword.fetch(opts, :sha256) do
      {:ok, sha} -> {:ok, sha}
      :error -> sha256(target)
    end
  end

  defp verify_layout(staging, platform) do
    exe = executable_path(staging, platform)
    if File.regular?(exe), do: :ok, else: {:error, {:extract_failed, {:missing_executable, exe}}}
  end

  defp platform_of("x86_64-linux"), do: {:linux, :x86_64}
  defp platform_of("aarch64-linux"), do: {:linux, :aarch64}
  defp platform_of("x86_64-macos"), do: {:darwin, :x86_64}
  defp platform_of("aarch64-macos"), do: {:darwin, :aarch64}
  defp platform_of("x86_64-windows"), do: {:windows, :x86_64}

  defp dir(opts), do: Keyword.get(opts, :dir) || dir()
end
