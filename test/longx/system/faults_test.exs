defmodule Longx.System.FaultsTest do
  @moduledoc """
  What went wrong on the server, kept where the person can see it: the
  socket loop of 0.2.5 was invisible until someone traced frames — the
  serializer had been logging encode failures nobody read.
  """
  use ExUnit.Case, async: false

  alias Longx.System.Faults

  setup do
    Faults.clear()
    :ok
  end

  test "faults are kept newest first, capped, with a kind, a detail and a time; a count of the recent ones" do
    assert Faults.recent() == []
    :ok = Faults.record(:socket_encode, "thread:x", "could not encode event: bad bytes")
    :ok = Faults.record(:wire_clean, "thread:y", "snapshot cleaned: a tuple in item bad")

    assert [
             %{kind: :wire_clean, where: "thread:y"},
             %{kind: :socket_encode, where: "thread:x", detail: detail, at: %DateTime{}}
           ] = Faults.recent()

    assert detail =~ "bad bytes"
    assert Faults.count_since(DateTime.add(DateTime.utc_now(), -60, :second)) == 2
    assert Faults.count_since(DateTime.add(DateTime.utc_now(), 60, :second)) == 0
    for i <- 1..150, do: Faults.record(:socket_encode, "t", "n#{i}")
    assert length(Faults.recent()) == Faults.keep()
    assert hd(Faults.recent()).detail == "n150"
  end

  test "the serializer and the wire cleaner record what they had to do" do
    alias Phoenix.Socket.Message

    msg = %Message{
      join_ref: "1",
      ref: nil,
      topic: "thread:t",
      event: "event",
      payload: %{"bad" => make_ref()}
    }

    LongxWeb.Socket.Serializer.encode!(msg)
    assert [%{kind: :socket_encode, where: "thread:t"}] = Faults.recent()

    Faults.clear()
    LongxWeb.Wire.clean(%{"a" => {:tuple}}, "thread:u")
    assert [%{kind: :wire_clean, where: "thread:u"}] = Faults.recent()
    # a clean payload records nothing
    LongxWeb.Wire.clean(%{"a" => 1}, "thread:u")
    assert length(Faults.recent()) == 1
  end
end
