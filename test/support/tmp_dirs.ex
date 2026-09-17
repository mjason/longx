defmodule Longx.Test.TmpDirs do
  @moduledoc """
  Removing a test's temporary directory when another process may still be
  writing into it (a test points a global directory — the knowledge's — at
  one of its own while an async test re-creates it): a plain `rm_rf` hit a
  directory that was not empty any more ("file already exists") and failed
  the test in its cleanup on CI.
  """

  @doc "`File.rm_rf!/1` with a few retries; the last failure raises."
  @spec rm_rf!(Path.t(), pos_integer) :: :ok
  def rm_rf!(dir, attempts \\ 5) do
    case File.rm_rf(dir) do
      {:ok, _} ->
        :ok

      {:error, _reason, _path} when attempts > 1 ->
        Process.sleep(100)
        rm_rf!(dir, attempts - 1)

      {:error, reason, path} ->
        raise File.Error,
          reason: reason,
          action: "remove files and directories recursively from",
          path: path
    end
  end
end
