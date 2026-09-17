defmodule Longx.Bundle do
  @moduledoc """
  Fetches a pinned upstream archive (`.tar.gz`, or `.zip` for Windows
  builds), verifies its sha256, unpacks it and swaps it into place atomically. Shared by the bundled runtimes
  (`Longx.Browser.Runtime`); nothing here knows what is
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
    * `:progress` — `fn {received, total | nil} -> … end`, called while a URL
      downloads (at most a few times a second), optional
    * `:on_stage` — `fn :verifying | :extracting -> … end`, optional
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
    progress = Keyword.get(opts, :progress) || fn _ -> :ok end
    on_stage = Keyword.get(opts, :on_stage) || fn _ -> :ok end

    with {:ok, archive} <-
           fetch(
             Keyword.fetch!(opts, :source),
             staging,
             Keyword.get(opts, :archive_name, "bundle.tar.gz"),
             progress
           ),
         :ok <- stage(on_stage, :verifying),
         :ok <- verify_checksum(archive, Keyword.fetch!(opts, :sha256)),
         :ok <- stage(on_stage, :extracting),
         :ok <- extract(archive, staging),
         :ok <- verify.(staging),
         :ok <- replace(staging, dest) do
      :ok
    else
      {:error, _} = error ->
        File.rm_rf(staging)
        # a parent this attempt created and nothing else uses goes with it
        File.rmdir(Path.dirname(dest))
        error
    end
  end

  defp stage(on_stage, name) do
    on_stage.(name)
    :ok
  end

  defp fetch(source, staging, archive_name, progress) do
    File.mkdir_p!(staging)
    archive = Path.join(staging, archive_name)

    case source do
      {:file, path} ->
        case File.cp(path, archive) do
          :ok -> {:ok, archive}
          {:error, reason} -> {:error, {:download_failed, reason}}
        end

      {:url, url} ->
        download(url, archive, progress)
    end
  end

  # streamed to the file chunk by chunk, the running count reported at most
  # every 200 ms (a 60 MB archive arrives in thousands of chunks)
  defp download(url, archive, progress) do
    file = File.open!(archive, [:write, :binary])

    sink = fn {:data, chunk}, {req, resp} ->
      IO.binwrite(file, chunk)
      received = (resp.private[:received] || 0) + byte_size(chunk)
      last = resp.private[:reported_at]
      # monotonic time starts negative on Linux: "0 = never reported" would
      # have meant "never report" — the settings card sat at 0 B for a whole download
      now = System.monotonic_time(:millisecond)

      resp =
        if last == nil or now - last >= 200 do
          progress.({received, content_length(resp)})
          Req.Response.put_private(resp, :reported_at, now)
        else
          resp
        end

      {:cont, {req, Req.Response.put_private(resp, :received, received)}}
    end

    result =
      case Req.get(url, into: sink, redirect: true, retry: false, receive_timeout: 600_000) do
        {:ok, %Req.Response{status: 200} = resp} ->
          progress.({resp.private[:received] || 0, content_length(resp)})
          {:ok, archive}

        {:ok, %Req.Response{status: status}} ->
          {:error, {:download_failed, {:status, status}}}

        {:error, reason} ->
          {:error, {:download_failed, reason}}
      end

    File.close(file)
    result
  end

  defp content_length(resp) do
    case Req.Response.get_header(resp, "content-length") do
      [value | _] ->
        case Integer.parse(value) do
          {n, _} -> n
          :error -> nil
        end

      _ ->
        nil
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
    result =
      if String.ends_with?(archive, ".zip") do
        case :zip.unzip(String.to_charlist(archive), [{:cwd, String.to_charlist(staging)}]) do
          {:ok, _files} -> :ok
          {:error, reason} -> {:error, reason}
        end
      else
        :erl_tar.extract(String.to_charlist(archive), [
          :compressed,
          {:cwd, String.to_charlist(staging)}
        ])
      end

    case result do
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
