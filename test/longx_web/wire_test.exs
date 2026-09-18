defmodule LongxWeb.WireTest do
  @moduledoc """
  Nothing a channel sends can kill the socket: payloads are made JSON-safe
  in the channel process (`Wire.clean/1`), and the serializer turns a
  leftover encode failure into an error frame instead of a crash — a
  transport crash closed the connection, the client reconnected and joined
  again, in a loop, for one thread's bad bytes.
  """
  use ExUnit.Case, async: true

  alias LongxWeb.Wire
  alias LongxWeb.Socket.Serializer
  alias Phoenix.Socket.{Broadcast, Message, Reply}

  test "clean/1: bytes that are not UTF-8, tuples, pids, functions and structs become JSON-safe values; the rest stays" do
    dirty = %{
      "text" => <<"PAR1", 0xFF, "x">>,
      "pair" => {:ok, 1},
      "pid" => self(),
      "fun" => &String.trim/1,
      "when" => ~U[2026-09-18 10:00:00Z],
      "nested" => [%{"deep" => {:a, "b"}}, 1.5, nil, true, :atom],
      "fine" => "ok"
    }

    cleaned = Wire.clean(dirty)
    assert {:ok, _} = Jason.encode(cleaned)
    assert cleaned["text"] =~ "PAR1"
    assert String.valid?(cleaned["text"])
    assert cleaned["pair"] == "{:ok, 1}"
    assert cleaned["pid"] =~ "#PID"
    assert cleaned["fun"] =~ "&String.trim/1"
    assert cleaned["when"] == "2026-09-18T10:00:00Z"
    assert [%{"deep" => "{:a, \"b\"}"}, 1.5, nil, true, :atom] = cleaned["nested"]
    assert cleaned["fine"] == "ok"
    # a clean payload is returned as it is (no copy, no cost)
    clean = %{"a" => [1, "b", %{"c" => true}]}
    assert Wire.clean(clean) == clean
  end

  test "the serializer answers an encode failure with an error frame, never a raise" do
    reply = %Reply{
      join_ref: "1",
      ref: "2",
      topic: "thread:x",
      status: :ok,
      payload: %{"bad" => {:tuple}}
    }

    assert {:socket_push, :text, iodata} = Serializer.encode!(reply)

    assert [
             _,
             _,
             "thread:x",
             "phx_reply",
             %{"status" => "error", "response" => %{"reason" => reason}}
           ] = Jason.decode!(IO.iodata_to_binary(iodata))

    assert reason =~ "encod"

    message = %Message{
      join_ref: "1",
      ref: nil,
      topic: "thread:x",
      event: "event",
      payload: %{"seq" => 3, "bad" => make_ref()}
    }

    assert {:socket_push, :text, iodata} = Serializer.encode!(message)

    assert [_, _, "thread:x", "longx/error", %{"reason" => _, "event" => "event"}] =
             Jason.decode!(IO.iodata_to_binary(iodata))

    broadcast = %Broadcast{topic: "notify", event: "event", payload: %{"bad" => self()}}
    assert {:socket_push, :text, iodata} = Serializer.fastlane!(broadcast)
    assert [nil, nil, "notify", "longx/error", _] = Jason.decode!(IO.iodata_to_binary(iodata))

    # a fine frame goes through untouched
    ok = %Message{join_ref: "1", ref: "5", topic: "t", event: "e", payload: %{"a" => 1}}
    assert Serializer.encode!(ok) == Phoenix.Socket.V2.JSONSerializer.encode!(ok)
  end
end
