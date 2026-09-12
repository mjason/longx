defmodule Longx.Codex.Framing do
  @moduledoc "Newline-delimited JSON framing for the app-server's stdio transport."

  @doc """
  Appends `chunk` to `buffer` and returns the complete lines (without their
  terminator, blank lines dropped) plus the unterminated tail.
  """
  @spec split(binary, binary) :: {[binary], binary}
  def split(buffer, chunk) do
    {complete, [tail]} = (buffer <> chunk) |> String.split("\n") |> Enum.split(-1)

    lines =
      complete
      |> Enum.map(&String.trim_trailing(&1, "\r"))
      |> Enum.reject(&(&1 == ""))

    {lines, tail}
  end
end
