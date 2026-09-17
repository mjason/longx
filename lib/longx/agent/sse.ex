defmodule Longx.Agent.SSE do
  @moduledoc """
  An incremental server-sent-events parser for the Responses API stream:
  `parse(buffer, chunk)` returns the complete events in the buffer so far
  as `{type, decoded_json}` and what remains of a partial event. The type
  is the `event:` line, else the payload's `"type"`. Comments, CRLF,
  `[DONE]` and undecodable data are skipped.
  """

  @type event :: {String.t(), map}

  @spec parse(binary, binary) :: {[event], binary}
  def parse(buffer, chunk) when is_binary(buffer) and is_binary(chunk) do
    data = buffer <> chunk
    # an event ends with a blank line; the last piece is incomplete unless
    # the data itself ends on one
    parts = String.split(data, ~r/\r?\n\r?\n/)
    {complete, [rest]} = Enum.split(parts, length(parts) - 1)
    {complete |> Enum.map(&event/1) |> Enum.reject(&is_nil/1), rest}
  end

  defp event(block) do
    lines = block |> String.split(~r/\r?\n/) |> Enum.reject(&String.starts_with?(&1, ":"))

    type = lines |> Enum.find_value(&field(&1, "event:"))
    data = lines |> Enum.flat_map(&List.wrap(field(&1, "data:"))) |> Enum.join("\n")

    case data do
      "" ->
        nil

      "[DONE]" ->
        nil

      json ->
        case Jason.decode(json) do
          {:ok, %{} = payload} -> {type || payload["type"] || "message", payload}
          _ -> nil
        end
    end
  end

  defp field(line, prefix) do
    if String.starts_with?(line, prefix),
      do:
        line
        |> binary_part(byte_size(prefix), byte_size(line) - byte_size(prefix))
        |> String.trim_leading(" "),
      else: nil
  end
end
