defmodule Longx.Codex.Runtime do
  @moduledoc """
  The bundled `codex-app-server` binary.

  We do not use whatever `codex` is on the machine: the app-server is pinned
  to one upstream release, downloaded from GitHub, checksum-verified against
  the hashes below (taken from that release's `codex-package_SHA256SUMS`) and
  unpacked into `priv/codex/<target>/`. Because it lives under `priv`, a
  `mix release` built after `mix codex.fetch` ships it.

  The `-package-` asset is used rather than the bare binary: on Linux the
  app-server needs the bundled `codex-resources/bwrap` next to itself for
  sandboxing, and the package is the only variant with published checksums.

      priv/codex/x86_64-unknown-linux-musl/
      ├── codex-package.json      # {version, target, entrypoint, ...}
      ├── bin/codex-app-server
      ├── codex-resources/bwrap, zsh/
      └── codex-path/rg

  Override the resolved executable with `LONGX_CODEX_APP_SERVER=/path`.
  """

  alias Longx.Platform

  @version "0.154.0"
  @release_tag "rust-v#{@version}"
  @base_url "https://github.com/openai/codex/releases/download/#{@release_tag}"
  @env_override "LONGX_CODEX_APP_SERVER"

  # sha256 of codex-app-server-package-<target>.tar.gz from codex-package_SHA256SUMS
  @sha256 %{
    "aarch64-apple-darwin" => "7bf20c1843bdcff086c89a294299833f20146ebbdba03e7f49f020b7adbfff7b",
    "aarch64-pc-windows-msvc" =>
      "7406aa3745acd5bd639b8921c0ee5e241861763606465cac643683944a849457",
    "aarch64-unknown-linux-musl" =>
      "295bb1b94a8b964b2d2461db9736b9907a9e4daa6ceb8e9bbb820b304fa897ed",
    "x86_64-apple-darwin" => "4fddde3689d2aa0058c06138a84b05f87bdbff8cd556fba5816a97ac0469a4d4",
    "x86_64-pc-windows-msvc" =>
      "5f8b43e030c0aeeb7bdb3d5e03fff4c68ba94fa2df0ae437c490811f54660d74",
    "x86_64-unknown-linux-musl" =>
      "b2450aaa4004d06790dd8a69d0246f4503ff1258400cc20de7d7a42ffe81b253"
  }

  @supported_platforms [
    {:linux, :x86_64},
    {:linux, :aarch64},
    {:darwin, :x86_64},
    {:darwin, :aarch64},
    {:windows, :x86_64},
    {:windows, :aarch64}
  ]

  @type target :: String.t()
  @type install_error ::
          {:checksum_mismatch, %{expected: String.t(), actual: String.t()}}
          | {:version_mismatch, %{expected: String.t(), actual: String.t()}}
          | {:download_failed, term}
          | {:extract_failed, term}
          | :unsupported_target

  @spec version() :: String.t()
  def version, do: @version

  @spec supported_platforms() :: [Platform.t()]
  def supported_platforms, do: @supported_platforms

  @spec asset_name(target) :: String.t()
  def asset_name(target), do: "codex-app-server-package-#{target}.tar.gz"

  @spec asset_url(target) :: String.t()
  def asset_url(target), do: "#{@base_url}/#{asset_name(target)}"

  @spec sha256(target) :: {:ok, String.t()} | {:error, :unsupported_target}
  def sha256(target) do
    case Map.fetch(@sha256, target) do
      {:ok, sha} -> {:ok, sha}
      :error -> {:error, :unsupported_target}
    end
  end

  @doc "Rust target triple of the machine we are running on."
  @spec current_target() :: target
  def current_target, do: Platform.rust_target(Platform.current())

  @doc "Default install root: `priv/codex` of the running application."
  @spec default_dir() :: Path.t()
  def default_dir, do: Application.app_dir(:longx, ["priv", "codex"])

  @doc """
  Path to the app-server executable for `target`, honouring
  `LONGX_CODEX_APP_SERVER`. `{:error, :not_installed}` if `install/2` (or
  `mix codex.fetch`) has not run yet.
  """
  @spec executable(target, keyword) :: {:ok, Path.t()} | {:error, :not_installed}
  def executable(target \\ current_target(), opts \\ []) do
    case System.get_env(@env_override) do
      path when is_binary(path) and path != "" ->
        {:ok, path}

      _ ->
        path = entrypoint_path(target, dir(opts))
        if File.regular?(path), do: {:ok, path}, else: {:error, :not_installed}
    end
  end

  @doc "Whether the package for `target` is unpacked under the install dir (ignores the env override)."
  @spec installed?(target, keyword) :: boolean
  def installed?(target \\ current_target(), opts \\ []) do
    File.regular?(entrypoint_path(target, dir(opts)))
  end

  @doc """
  Downloads (or copies from `source: {:file, path}`), verifies and unpacks the
  package for `target` into `dir`, replacing any previous install.

  Options: `:dir` (default `default_dir/0`), `:source` (`{:url, url}` default,
  or `{:file, path}`), `:sha256` (default: the pinned hash for `target`).
  """
  @spec install(target, keyword) :: {:ok, Path.t()} | {:error, install_error}
  def install(target, opts \\ []) do
    root = dir(opts)
    dest = Path.join(root, target)
    staging = Path.join(root, ".staging-#{target}-#{System.unique_integer([:positive])}")

    with {:ok, expected} <- expected_sha(target, opts),
         {:ok, archive} <- fetch(target, opts, staging),
         :ok <- verify_checksum(archive, expected),
         :ok <- extract(archive, staging),
         :ok <- verify_manifest(staging, target),
         :ok <- replace(staging, dest) do
      {:ok, entrypoint_path(target, root)}
    else
      {:error, _} = error ->
        File.rm_rf(staging)
        error
    end
  end

  ## Steps

  defp expected_sha(target, opts) do
    case Keyword.fetch(opts, :sha256) do
      {:ok, sha} -> {:ok, sha}
      :error -> sha256(target)
    end
  end

  defp fetch(target, opts, staging) do
    File.mkdir_p!(staging)
    archive = Path.join(staging, asset_name(target))

    case Keyword.get(opts, :source, {:url, asset_url(target)}) do
      {:file, path} ->
        case File.cp(path, archive) do
          :ok -> {:ok, archive}
          {:error, reason} -> {:error, {:download_failed, reason}}
        end

      {:url, url} ->
        download(url, archive)
    end
  end

  defp download(url, archive) do
    case Req.get(url, into: File.stream!(archive), redirect: true, receive_timeout: 600_000) do
      {:ok, %Req.Response{status: 200}} -> {:ok, archive}
      {:ok, %Req.Response{status: status}} -> {:error, {:download_failed, {:status, status}}}
      {:error, reason} -> {:error, {:download_failed, reason}}
    end
  end

  defp verify_checksum(archive, expected) do
    actual =
      archive
      |> File.stream!(1_048_576)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    if actual == String.downcase(expected),
      do: :ok,
      else: {:error, {:checksum_mismatch, %{expected: expected, actual: actual}}}
  end

  defp extract(archive, staging) do
    case :erl_tar.extract(String.to_charlist(archive), [
           :compressed,
           {:cwd, String.to_charlist(staging)}
         ]) do
      :ok ->
        File.rm(archive)
        :ok

      {:error, reason} ->
        {:error, {:extract_failed, reason}}
    end
  end

  defp verify_manifest(staging, target) do
    with {:ok, json} <- File.read(Path.join(staging, "codex-package.json")),
         {:ok, %{"version" => version}} <- Jason.decode(json) do
      if version == @version,
        do: :ok,
        else: {:error, {:version_mismatch, %{expected: @version, actual: version}}}
    else
      _ -> {:error, {:extract_failed, {:missing_manifest, target}}}
    end
  end

  defp replace(staging, dest) do
    File.rm_rf!(dest)
    File.mkdir_p!(Path.dirname(dest))

    case File.rename(staging, dest) do
      :ok -> :ok
      {:error, reason} -> {:error, {:extract_failed, {:rename, reason}}}
    end
  end

  ## Paths

  defp dir(opts), do: Keyword.get(opts, :dir) || default_dir()

  defp entrypoint_path(target, root) do
    suffix = if String.contains?(target, "windows"), do: ".exe", else: ""
    Path.join([root, target, "bin", "codex-app-server#{suffix}"])
  end
end
