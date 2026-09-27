defmodule Longx.Tls.Tool do
  @moduledoc """
  **longx-cert** (github.com/mjason/longx-cert, Go, lego inside) — what
  obtains the HTTPS certificate through the ACME DNS-01 challenge with any
  of lego's DNS providers. It is not bundled: `Longx.Tls.Manager` downloads
  it the first time a certificate is asked for, into
  `<dir>/<version>/<target>/` (`config :longx, Longx.Tls, tool_dir:` — dev
  `data/longx-cert`, prod `$LONGX_DATA_DIR/longx-cert`), the way
  `Longx.Browser.Runtime` handles obscura.

  Pinned to one release with a sha256 per target, taken from the release's
  `SHA256SUMS` when pinning and verified on every download. Each archive
  holds `longx-cert` (`.exe` on Windows) and its LICENSE at the root.
  `priv/tls/providers.json` is that release's `longx-cert providers`, so the
  settings page lists the DNS providers before anything is downloaded —
  bump both together.

  `LONGX_CERT=/path/to/longx-cert` overrides the resolved binary.
  """

  alias Longx.Platform

  @version "0.1.0"
  @base_url "https://github.com/mjason/longx-cert/releases/download/v#{@version}"
  @env_override "LONGX_CERT"

  # from the release's SHA256SUMS
  @sha256 %{
    "darwin-amd64" => "54ba474aee3446287b411c880be67690222d18c018629baa093956c9b459cfa8",
    "darwin-arm64" => "c9934f186856991bef0c2d2a201ed9be081111f96fc9b713991607d0b05a7fbd",
    "linux-amd64" => "76f0f059c04ac39e3b85d7e72427050a4ae9d99df8a565ef8627b7fac7302fae",
    "linux-arm64" => "2ef75f8eb1887ecf47e247839973d1074c680a1b0212f16c5058ce7bf460108f",
    "windows-amd64" => "4ef872da3bd12c39edb383956cda9813f611018ac419f6b40a35f94ad65dbcef",
    "windows-arm64" => "df7cf6db487740a498b9a2aac7a34a4bd8722c2ac74422bbb78dc58559abde2e"
  }

  @type target :: String.t()

  @spec version() :: String.t()
  def version, do: @version

  @doc "Go's `<os>-<arch>` for a platform: every platform Longx runs on has a build."
  @spec target(Platform.t()) :: target
  def target(platform) do
    {goos, goarch} = Platform.go_target(platform)
    "#{goos}-#{goarch}"
  end

  @spec current_target() :: target
  def current_target, do: target(Platform.current())

  @spec asset_name(target) :: String.t()
  def asset_name("windows-" <> _ = target), do: "longx-cert-#{target}.zip"
  def asset_name(target), do: "longx-cert-#{target}.tar.gz"

  @spec asset_url(target) :: String.t()
  def asset_url(target), do: "#{@base_url}/#{asset_name(target)}"

  @spec sha256(target) :: {:ok, String.t()} | {:error, :unsupported_target}
  def sha256(target) do
    case Map.fetch(@sha256, target) do
      {:ok, sha} -> {:ok, sha}
      :error -> {:error, :unsupported_target}
    end
  end

  @doc "Where releases are installed (`config :longx, Longx.Tls, tool_dir:`)."
  @spec dir(keyword) :: Path.t()
  def dir(opts \\ []) do
    Keyword.get(opts, :dir) ||
      Keyword.get(Application.get_env(:longx, Longx.Tls, []), :tool_dir) ||
      Path.expand("data/longx-cert")
  end

  @spec executable_path(Path.t(), target) :: Path.t()
  def executable_path(root, "windows-" <> _), do: Path.join(root, "longx-cert.exe")
  def executable_path(root, _target), do: Path.join(root, "longx-cert")

  @doc """
  What runs: `LONGX_CERT` (`:env`), else our download (`:downloaded` — the
  pinned version, else the newest older one so certificates still renew
  right after a Longx upgrade). A `longx-cert` on PATH is never picked up.
  """
  @spec resolve(target, keyword) :: {:ok, :env | :downloaded, Path.t()} | {:error, :not_installed}
  def resolve(target \\ current_target(), opts \\ []) do
    case System.get_env(@env_override) do
      path when is_binary(path) and path != "" ->
        {:ok, :env, path}

      _ ->
        case installed_versions(target, opts) do
          [newest | _] -> {:ok, :downloaded, executable_path(root(target, newest, opts), target)}
          [] -> {:error, :not_installed}
        end
    end
  end

  @doc "The pinned version is installed for `target`."
  @spec installed?(target, keyword) :: boolean
  def installed?(target \\ current_target(), opts \\ []),
    do: File.regular?(executable_path(root(target, @version, opts), target))

  @doc "Every downloaded version holding the binary for `target`, newest first."
  @spec installed_versions(target, keyword) :: [String.t()]
  def installed_versions(target, opts \\ []) do
    case File.ls(dir(opts)) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&match?({:ok, _}, Version.parse(&1)))
        |> Enum.filter(&File.regular?(executable_path(root(target, &1, opts), target)))
        |> Enum.sort({:desc, Version})

      {:error, _} ->
        []
    end
  end

  @doc "Removes every downloaded version of `target` but the pinned one."
  @spec prune_old(target, keyword) :: :ok
  def prune_old(target, opts \\ []) do
    for version <- installed_versions(target, opts), version != @version do
      File.rm_rf!(root(target, version, opts))
      _ = File.rmdir(Path.join(dir(opts), version))
    end

    :ok
  end

  @doc """
  Downloads (or copies), verifies and unpacks the archive for `target`
  through `Longx.Bundle.install/1`. Options: `source:`, `sha256:`, `dir:`,
  `progress:` (`fn {received, total} -> … end`), `on_stage:`.
  """
  @spec install(target, keyword) :: {:ok, Path.t()} | {:error, term}
  def install(target, opts \\ []) do
    root = root(target, @version, opts)

    with {:ok, expected} <- expected_sha(target, opts),
         :ok <-
           Longx.Bundle.install(
             source: Keyword.get(opts, :source, {:url, asset_url(target)}),
             sha256: expected,
             dest: root,
             archive_name: asset_name(target),
             verify: &verify_layout(&1, target),
             progress: Keyword.get(opts, :progress),
             on_stage: Keyword.get(opts, :on_stage)
           ) do
      {:ok, executable_path(root, target)}
    end
  end

  defp root(target, version, opts), do: Path.join([dir(opts), version, target])

  defp expected_sha(target, opts) do
    case Keyword.fetch(opts, :sha256) do
      {:ok, sha} -> {:ok, sha}
      :error -> sha256(target)
    end
  end

  defp verify_layout(staging, target) do
    exe = executable_path(staging, target)
    if File.regular?(exe), do: :ok, else: {:error, {:extract_failed, {:missing_executable, exe}}}
  end
end
