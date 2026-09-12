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

  test "ChatGPT-only requests and unknown methods are rejected with method-not-found" do
    for method <- [
          "account/chatgptAuthTokens/refresh",
          "attestation/generate",
          "item/tool/call",
          "something/new"
        ] do
      assert {:error, -32601, _} = Default.handle(method, %{}, @ctx)
    end
  end
end
