defmodule LongxWeb.Wire do
  @moduledoc """
  What a channel sends must encode to JSON, whatever the view holds.

  Phoenix encodes a reply or a push in the socket transport process; a
  term Jason cannot take there — bytes that are not UTF-8, a tuple, a pid,
  a struct — crashed the transport, which closed the connection, and the
  client reconnected and joined again, in a loop, for every page showing
  that thread. `clean/1` walks a payload in the channel process first:
  invalid bytes scrubbed, `DateTime`s to ISO strings, anything else JSON
  has no shape for `inspect`ed. A clean payload comes back as it is.
  """

  alias Longx.Agent.Text

  @spec clean(term, String.t() | nil) :: term
  def clean(term, where \\ nil) do
    if encodable?(term) do
      term
    else
      Longx.System.Faults.record(
        :wire_clean,
        where,
        "a payload held what JSON cannot take; cleaned"
      )

      walk(term)
    end
  end

  # a cheap check first: the common case is a clean payload
  defp encodable?(term) do
    match?({:ok, _}, Jason.encode(term))
  rescue
    _ -> false
  end

  defp walk(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp walk(%NaiveDateTime{} = at), do: NaiveDateTime.to_iso8601(at)
  defp walk(%Date{} = d), do: Date.to_iso8601(d)
  defp walk(%Decimal{} = d), do: Decimal.to_string(d)
  defp walk(%_{} = struct), do: inspect(struct)
  defp walk(map) when is_map(map), do: Map.new(map, fn {k, v} -> {key(k), walk(v)} end)
  defp walk(list) when is_list(list), do: Enum.map(list, &walk/1)
  defp walk(text) when is_binary(text), do: Text.utf8(text)
  defp walk(value) when is_number(value) or is_boolean(value) or is_nil(value), do: value
  defp walk(atom) when is_atom(atom), do: atom
  defp walk(other), do: inspect(other)

  defp key(k) when is_binary(k), do: Text.utf8(k)
  defp key(k) when is_atom(k), do: k
  defp key(k), do: inspect(k)
end
