defmodule Longx.Git.Runtime do
  @moduledoc """
  The bundled `git` (with `git-lfs`) Longx runs for every repository
  operation, on every platform, regardless of what the machine has.

  Built by GitHub Desktop's `desktop/dugite-native` project: a relocatable
  git for macOS/Linux/Windows with git-lfs and git-remote-https. Pinned to
  one release with per-target sha256 (from the release's `.sha256` assets),
  fetched by `mix git.fetch` into `priv/git/<target>/` — the same scheme as
  `Longx.Codex.Runtime`, so a release built after fetching ships it.

  Environment and paths follow dugite's own `git-environment.ts`
  (`GIT_EXEC_PATH`, bundle-provided system gitconfig and templates, the
  bundled CA file on Linux, `mingw64` layout on Windows). Being real git,
  the user's `~/.gitconfig`, hooks, credential helpers and signing all apply.

  `LONGX_GIT=/path/to/git` overrides the resolved binary.
  """

  alias Longx.Platform

  @version "2.53.0"
  @release_tag "v2.53.0-4"
  @asset_prefix "dugite-native-v2.53.0-4098283"
  @base_url "https://github.com/desktop/dugite-native/releases/download/#{@release_tag}"
  @env_override "LONGX_GIT"

  # from the release's *.tar.gz.sha256 assets
  @sha256 %{
    "macOS-arm64" => "f9dc64635a5b62fbd7ad95db73268bbb8912255ac516d65d37bf7af22fcb8ffe",
    "macOS-x64" => "ae6686718aa34f4140424db16b92a47dcffd6d1f312eb8b5f3b267f7404e2680",
    "ubuntu-arm64" => "a161f45af4626bb7e0c688854bd4a9aee47cc514bca404cff0a5e3536ef1c0af",
    "ubuntu-x64" => "cca76aa31ad9e835e771ee7f55b73934777fbd8d16757a10d307ba06de860901",
    "windows-arm64" => "1abbeb3a2ce06e9b80e75bb888dce959b6c73bdb11ccc670a01a71d64f4422a5",
    "windows-x64" => "7b76bc5c32c0d7c5984efdc2a8a32697cf1e8a43bc55176fbf9869c0ee995130"
  }

  @type target :: String.t()

  @spec version() :: String.t()
  def version, do: @version

  @spec release_tag() :: String.t()
  def release_tag, do: @release_tag

  @spec asset_name(target) :: String.t()
  def asset_name(target), do: "#{@asset_prefix}-#{target}.tar.gz"

  @spec asset_url(target) :: String.t()
  def asset_url(target), do: "#{@base_url}/#{asset_name(target)}"

  @spec sha256(target) :: {:ok, String.t()} | {:error, :unsupported_target}
  def sha256(target) do
    case Map.fetch(@sha256, target) do
      {:ok, sha} -> {:ok, sha}
      :error -> {:error, :unsupported_target}
    end
  end

  @doc "dugite-native's name for a platform."
  @spec target(Platform.t()) :: target
  def target({:linux, :x86_64}), do: "ubuntu-x64"
  def target({:linux, :aarch64}), do: "ubuntu-arm64"
  def target({:darwin, :x86_64}), do: "macOS-x64"
  def target({:darwin, :aarch64}), do: "macOS-arm64"
  def target({:windows, :x86_64}), do: "windows-x64"
  def target({:windows, :aarch64}), do: "windows-arm64"

  @spec current_target() :: target
  def current_target, do: target(Platform.current())

  @spec default_dir() :: Path.t()
  def default_dir, do: Application.app_dir(:longx, ["priv", "git"])

  ## Layout (dugite conventions)

  @spec executable_path(Path.t(), Platform.t()) :: Path.t()
  def executable_path(root, {:windows, _}), do: Path.join([root, "cmd", "git.exe"])
  def executable_path(root, _platform), do: Path.join([root, "bin", "git"])

  @doc "Environment to run the bundled git with. `base` is the process env to extend (Windows PATH)."
  @spec env(Path.t(), Platform.t(), %{optional(String.t()) => String.t()}) :: [
          {String.t(), String.t()}
        ]
  def env(root, platform, base \\ %{}) do
    [{"GIT_TERMINAL_PROMPT", "0"}, {"LC_ALL", "C"}] ++ platform_env(root, platform, base)
  end

  defp platform_env(root, {:windows, _}, base) do
    mingw = Path.join(root, "mingw64")

    [
      {"GIT_EXEC_PATH", Path.join([mingw, "libexec", "git-core"])},
      {"PATH",
       Enum.join(
         [Path.join(mingw, "bin"), Path.join([mingw, "usr", "bin"]), Map.get(base, "PATH", "")],
         ";"
       )}
    ]
  end

  defp platform_env(root, {os, _}, _base) do
    common = [
      {"GIT_EXEC_PATH", Path.join([root, "libexec", "git-core"])},
      # dugite ships sane defaults in its own system gitconfig; user/global config still overrides
      {"GIT_CONFIG_SYSTEM", Path.join([root, "etc", "gitconfig"])},
      {"GIT_TEMPLATE_DIR", Path.join([root, "share", "git-core", "templates"])}
    ]

    case os do
      :linux ->
        common ++ [{"PREFIX", root}, {"GIT_SSL_CAINFO", Path.join([root, "ssl", "cacert.pem"])}]

      _ ->
        common
    end
  end

  ## Resolution

  @doc "Path to the bundled git for `target`, honouring `LONGX_GIT`."
  @spec executable(target, keyword) :: {:ok, Path.t()} | {:error, :not_installed}
  def executable(target \\ current_target(), opts \\ []) do
    case System.get_env(@env_override) do
      path when is_binary(path) and path != "" ->
        {:ok, path}

      _ ->
        path = executable_path(Path.join(dir(opts), target), platform_of(target))
        if File.regular?(path), do: {:ok, path}, else: {:error, :not_installed}
    end
  end

  @spec installed?(target, keyword) :: boolean
  def installed?(target \\ current_target(), opts \\ []) do
    File.regular?(executable_path(Path.join(dir(opts), target), platform_of(target)))
  end

  @doc "Root directory of the installed bundle for `target`."
  @spec root(target, keyword) :: Path.t()
  def root(target \\ current_target(), opts \\ []), do: Path.join(dir(opts), target)

  @doc "Downloads (or copies), verifies and unpacks the bundle for `target`; see `Longx.Bundle.install/1`."
  @spec install(target, keyword) :: {:ok, Path.t()} | {:error, term}
  def install(target, opts \\ []) do
    root = Path.join(dir(opts), target)
    platform = platform_of(target)

    with {:ok, expected} <- expected_sha(target, opts),
         :ok <-
           Longx.Bundle.install(
             source: Keyword.get(opts, :source, {:url, asset_url(target)}),
             sha256: expected,
             dest: root,
             archive_name: asset_name(target),
             verify: &verify_layout(&1, platform)
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

  defp platform_of("ubuntu-x64"), do: {:linux, :x86_64}
  defp platform_of("ubuntu-arm64"), do: {:linux, :aarch64}
  defp platform_of("macOS-x64"), do: {:darwin, :x86_64}
  defp platform_of("macOS-arm64"), do: {:darwin, :aarch64}
  defp platform_of("windows-x64"), do: {:windows, :x86_64}
  defp platform_of("windows-arm64"), do: {:windows, :aarch64}

  defp dir(opts), do: Keyword.get(opts, :dir) || default_dir()
end
