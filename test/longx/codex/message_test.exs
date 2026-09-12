defmodule Longx.Codex.MessageTest do
  use ExUnit.Case, async: true

  alias Longx.Codex.{Error, Message}

  describe "encoding" do
    test "request / notification / response / error_response wire shapes (no jsonrpc field, like codex)" do
      assert Message.request(7, "thread/start", %{cwd: "/x"}) == %{
               "id" => 7,
               "method" => "thread/start",
               "params" => %{cwd: "/x"}
             }

      assert Message.notification("initialized", %{}) == %{
               "method" => "initialized",
               "params" => %{}
             }

      assert Message.response(7, %{"ok" => true}) == %{"id" => 7, "result" => %{"ok" => true}}

      assert Message.error_response(7, -32601, "nope") == %{
               "id" => 7,
               "error" => %{"code" => -32601, "message" => "nope"}
             }
    end

    test "encode/1 is one JSON line (iodata)" do
      line = Message.encode(Message.notification("initialized", %{})) |> IO.iodata_to_binary()
      assert String.ends_with?(line, "\n")
      assert Jason.decode!(line) == %{"method" => "initialized", "params" => %{}}
    end
  end

  describe "classify/1" do
    test "server → client request has both id and method" do
      assert Message.classify(%{
               "id" => 5,
               "method" => "item/commandExecution/requestApproval",
               "params" => %{"x" => 1}
             }) ==
               {:server_request, 5, "item/commandExecution/requestApproval", %{"x" => 1}}
    end

    test "successful response" do
      assert Message.classify(%{"id" => 1, "result" => %{"thread" => %{}}}) ==
               {:response, 1, {:ok, %{"thread" => %{}}}}
    end

    test "error response becomes a %Longx.Codex.Error{}" do
      assert {:response, 2,
              {:error, %Error{code: -32600, message: "Invalid request: x", data: nil}}} =
               Message.classify(%{
                 "id" => 2,
                 "error" => %{"code" => -32600, "message" => "Invalid request: x"}
               })

      assert {:response, 3, {:error, %Error{data: %{"k" => "v"}}}} =
               Message.classify(%{
                 "id" => 3,
                 "error" => %{"code" => 1, "message" => "m", "data" => %{"k" => "v"}}
               })
    end

    test "notification has method but no id; missing params become an empty map" do
      assert Message.classify(%{"method" => "turn/started", "params" => %{"a" => 1}}) ==
               {:notification, "turn/started", %{"a" => 1}}

      assert Message.classify(%{"method" => "ping"}) == {:notification, "ping", %{}}
    end

    test "anything else is unknown" do
      assert Message.classify(%{"foo" => 1}) == {:unknown, %{"foo" => 1}}
      assert Message.classify("nope") == {:unknown, "nope"}
    end
  end

  test "Error is an exception with a useful message" do
    assert Exception.message(%Error{code: -32600, message: "bad"}) == "codex error -32600: bad"
  end
end
