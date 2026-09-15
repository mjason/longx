defmodule Longx.Exec.PathUri do
  @moduledoc """
  codex's `PathUri`: every path on the exec-server wire is a `file:` URI
  (`file:///home/mj/%E6%95%B0%E5%AD%A6`) — UTF-8 percent-encoded, no
  authority, always absolute. Only the POSIX form is spoken here; the
  exec-server runs on the machine codex runs on, never on Windows (a Windows
  install keeps codex's own executor).
  """

  @doc "The native path of a `file:` URI."
  @spec to_path(term) :: {:ok, Path.t()} | {:error, String.t()}
  def to_path("file:///" <> rest) do
    case URI.decode("/" <> rest) do
      path when is_binary(path) and byte_size(path) > 0 -> {:ok, path}
    end
  rescue
    ArgumentError -> {:error, "malformed percent-encoding in file URI"}
  end

  def to_path("file://" <> _ = uri), do: {:error, "file URI with an authority: #{uri}"}
  def to_path(uri) when is_binary(uri), do: {:error, "not a file URI: #{uri}"}
  def to_path(_), do: {:error, "not a file URI"}

  @doc "The `file:` URI of an absolute native path."
  @spec from_path(Path.t()) :: String.t()
  def from_path("/" <> _ = path) do
    "file://" <>
      (path
       |> String.split("/")
       |> Enum.map_join("/", &URI.encode(&1, fn c -> URI.char_unreserved?(c) end)))
  end
end
