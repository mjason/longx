defmodule Longx.Agent.Text do
  @moduledoc """
  Bytes that are not UTF-8 never reach the view or the transcript.

  A tool's output is whatever a command wrote — a parquet file `cat`ed, a
  clip that cut a multibyte character in half. Jason refuses such a binary,
  and the place it refused was the socket transport encoding a join reply:
  the socket closed, the client reconnected and joined again, 146 times in
  five seconds, for every page that showed that thread. So every binary is
  scrubbed (`U+FFFD` for each invalid sequence) where it enters: a shell
  chunk, a result, an item folded into the store.
  """

  @doc "The binary with every invalid UTF-8 sequence replaced by U+FFFD; anything else as it is."
  @spec utf8(term) :: term
  def utf8(text) when is_binary(text) do
    if String.valid?(text), do: text, else: scrub(text, [])
  end

  def utf8(other), do: other

  @doc "`utf8/1` over every binary inside maps and lists."
  @spec deep(term) :: term
  def deep(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {k, deep(v)} end)

  def deep(list) when is_list(list), do: Enum.map(list, &deep/1)
  def deep(other), do: utf8(other)

  defp scrub(<<char::utf8, rest::binary>>, acc), do: scrub(rest, [acc, <<char::utf8>>])
  defp scrub(<<_bad, rest::binary>>, acc), do: scrub(rest, [acc, "�"])
  defp scrub(<<>>, acc), do: IO.iodata_to_binary(acc)
end
