defmodule Longx.Bundle do
  @moduledoc """
  Fetches a pinned upstream tarball, verifies its sha256, unpacks it and
  swaps it into place atomically. Shared by the bundled runtimes
  (`Longx.Codex.Runtime`, `Longx.Git.Runtime`); nothing here knows what is
  inside the archive beyond an optional `:verify` step run on the unpacked
  tree before it goes live.
  """

  @type source :: {:url, String.t()} | {:file, Path.t()}
  @type error ::
          {:checksum_mismatch, %{expected: String.t(), actual: String.t()}}
          | {:download_failed, term}
          | {:extract_failed, term}
          | term

  @doc """
  Options:
    * `:source` — `{:url, url}` (downloaded with Req) or `{:file, path}`
    * `:sha256` — expected hex digest of the archive
    * `:dest` — directory that will hold the unpacked tree (replaced if present)
    * `:archive_name` — file name to give the archive while staging
    * `:verify` — `fn staging_dir -> :ok | {:error, term} end`, optional
  """
  @spec install(keyword) :: :ok | {:error, error}
  def install(opts) do
    dest = Keyword.fetch!(opts, :dest)

    staging =
      Path.join(
        Path.dirname(dest),
        ".staging-#{Path.basename(dest)}-#{System.unique_integer([:positive])}"
      )

    verify = Keyword.get(opts, :verify, fn _ -> :ok end)

    with {:ok, archive} <-
           fetch(
             Keyword.fetch!(opts, :source),
             staging,
             Keyword.get(opts, :archive_name, "bundle.tar.gz")
           ),
         :ok <- verify_checksum(archive, Keyword.fetch!(opts, :sha256)),
         :ok <- extract(archive, staging),
         :ok <- verify.(staging),
         :ok <- replace(staging, dest) do
      :ok
    else
      {:error, _} = error ->
        File.rm_rf(staging)
        error
    end
  end

  defp fetch(source, staging, archive_name) do
    File.mkdir_p!(staging)
    archive = Path.join(staging, archive_name)

    case source do
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

  @doc "Streams a file through sha256 and compares with `expected` (hex, case-insensitive)."
  @spec verify_checksum(Path.t(), String.t()) :: :ok | {:error, {:checksum_mismatch, map}}
  def verify_checksum(path, expected) do
    actual =
      path
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

  defp replace(staging, dest) do
    File.rm_rf!(dest)
    File.mkdir_p!(Path.dirname(dest))

    case File.rename(staging, dest) do
      :ok -> :ok
      {:error, reason} -> {:error, {:extract_failed, {:rename, reason}}}
    end
  end
end
