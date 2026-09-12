defmodule Longx.Codex.ServerRequestTest do
  use ExUnit.Case, async: true

  alias Longx.Codex.ServerRequest.Default

  @ctx %{thread_id: "t1"}

  test "approvals and questions are deferred with a decline-style fallback" do
    for {method, fallback} <- [
          {"item/commandExecution/requestApproval", %{"decision" => "decline"}},
          {"item/fileChange/requestApproval", %{"decision" => "decline"}},
          {"execCommandApproval", %{"decision" => "timed_out"}},
          {"applyPatchApproval", %{"decision" => "timed_out"}},
          {"item/permissions/requestApproval", %{"permissions" => %{}}},
          {"item/tool/requestUserInput", %{"answers" => %{}}},
          {"mcpServer/elicitation/request", %{"action" => "cancel"}}
        ] do
      assert {:defer, timeout, {:reply, ^fallback}} = Default.handle(method, %{}, @ctx)
      assert is_integer(timeout) and timeout > 0
    end
  end

  test "dynamic tool calls run asynchronously through the Runner, with a failed-call fallback" do
    params = %{
      "tool" => "echo",
      "namespace" => "test",
      "arguments" => %{"message" => "x"},
      "callId" => "c",
      "threadId" => "t",
      "turnId" => "u"
    }

    assert {:async, fun, timeout, {:reply, %{"success" => false}}} =
             Default.handle("item/tool/call", params, @ctx)

    assert is_integer(timeout)
    assert {:reply, %{"success" => true, "contentItems" => [%{"text" => "echo: x"}]}} = fun.()
  end

  test "ChatGPT-only requests are refused explicitly (not as unknown methods)" do
    for method <- ["account/chatgptAuthTokens/refresh", "attestation/generate"] do
      assert {:error, -32000, message} = Default.handle(method, %{}, @ctx)
      assert message =~ "ChatGPT"
    end
  end

  test "unknown methods are method-not-found" do
    assert {:error, -32601, _} = Default.handle("something/new", %{}, @ctx)
  end
end
