defmodule Longx.Agent.SSETest do
  use ExUnit.Case, async: true

  alias Longx.Agent.SSE

  test "parses complete events and keeps a partial one" do
    chunk = "event: a\ndata: {\"x\":1}\n\nevent: b\ndata: {\"y\":2}\n\nevent: c\ndata: {\"z\""

    assert {[{"a", %{"x" => 1}}, {"b", %{"y" => 2}}], rest} = SSE.parse("", chunk)
    assert {[{"c", %{"z" => 3}}], ""} = SSE.parse(rest, ":3}\n\n")
  end

  test "a data-only event takes its type from the payload; comments and CRLF are fine" do
    assert {[{"response.completed", %{"type" => "response.completed"}}], ""} =
             SSE.parse("", ": keepalive\r\ndata: {\"type\":\"response.completed\"}\r\n\r\n")
  end

  test "multi-line data is joined; [DONE] and undecodable data are skipped" do
    assert {[{"m", %{"a" => 1}}], ""} =
             SSE.parse("", "event: m\ndata: {\"a\":\ndata: 1}\n\ndata: [DONE]\n\ndata: nope\n\n")
  end
end
