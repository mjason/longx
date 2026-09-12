defmodule Longx.Codex.FramingTest do
  use ExUnit.Case, async: true

  alias Longx.Codex.Framing

  test "complete lines come out, the partial tail stays buffered" do
    assert Framing.split("", ~s({"a":1}\n{"b":2}\n{"c")) == {[~s({"a":1}), ~s({"b":2})], ~s({"c")}
  end

  test "the tail is completed by the next chunk" do
    {[], rest} = Framing.split("", ~s({"a":))
    assert Framing.split(rest, ~s(1}\n)) == {[~s({"a":1})], ""}
  end

  test "empty lines and CRLF are tolerated" do
    assert Framing.split("", "\n\r\n{\"a\":1}\r\n\n") == {[~s({"a":1})], ""}
  end

  test "a chunk without a newline yields nothing" do
    assert Framing.split("", "abc") == {[], "abc"}
  end
end
