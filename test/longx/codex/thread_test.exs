defmodule Longx.Codex.ThreadTest do
  use ExUnit.Case, async: false

  alias Longx.Codex.{Connection, Thread, ThreadState}

  @fake Path.expand("test/support/fake_app_server.exs")

  describe "params/1 (pure)" do
    test "snake_case options become codex's camelCase / kebab-case values" do
      assert Thread.start_params(
               cwd: "/p",
               approval_policy: :never,
               sandbox: :read_only,
               model_context_window: 64_000,
               tools: []
             ) ==
               %{
                 "cwd" => "/p",
                 "approvalPolicy" => "never",
                 "sandbox" => "read-only",
                 "config" => %{"model_context_window" => 64_000}
               }

      assert Thread.start_params(
               cwd: "/p",
               approval_policy: :on_request,
               sandbox: :workspace_write,
               tools: []
             ) ==
               %{"cwd" => "/p", "approvalPolicy" => "on-request", "sandbox" => "workspace-write"}

      assert Thread.start_params(
               cwd: "/p",
               sandbox: :danger_full_access,
               approval_policy: :untrusted
             )["sandbox"] == "danger-full-access"
    end

    test "tools: :auto declares every available registered tool as dynamicTools" do
      params = Thread.start_params(cwd: "/p", tools: :auto)
      namespaces = Enum.map(params["dynamicTools"], & &1["name"])
      assert "builtin" in namespaces
      assert "test" in namespaces
      builtin = Enum.find(params["dynamicTools"], &(&1["name"] == "builtin"))
      assert Enum.any?(builtin["tools"], &(&1["name"] == "thread_status"))
    end

    test "tools: [] declares nothing; tools: [modules] only those" do
      refute Map.has_key?(Thread.start_params(cwd: "/p", tools: []), "dynamicTools")

      [only] = Thread.start_params(cwd: "/p", tools: [Longx.Tools.Builtin.Echo])["dynamicTools"]
      assert only["name"] == "builtin"
      assert Enum.map(only["tools"], & &1["name"]) == ["echo"]
    end

    test "defaults: on-request approvals in a workspace-write sandbox" do
      assert %{"approvalPolicy" => "on-request", "sandbox" => "workspace-write"} =
               Thread.start_params(cwd: "/p")
    end

    test "cwd is required" do
      assert_raise KeyError, fn -> Thread.start_params([]) end
    end

    test "decisions map to codex's enum" do
      assert Thread.decision(:accept) == %{"decision" => "accept"}
      assert Thread.decision(:accept_for_session) == %{"decision" => "acceptForSession"}
      assert Thread.decision(:decline) == %{"decision" => "decline"}
      assert Thread.decision(:cancel) == %{"decision" => "cancel"}
    end
  end

  describe "against the fake app-server" do
    setup do
      conn = start_supervised!({Connection, name: nil, command: ["elixir", @fake], env: []})
      %{conn: conn}
    end

    test "start → send → completed turn, then resume backfills a fresh ThreadState", %{conn: conn} do
      {:ok, thread_id} = Thread.start(cwd: "/", conn: conn)
      Thread.subscribe(thread_id)

      {:ok, turn_id} = Thread.send(thread_id, "say hi there", conn: conn)

      assert_receive {:codex, _, "turn/completed",
                      %{"turn" => %{"id" => ^turn_id, "status" => "completed"}}},
                     10_000

      assert Enum.find(Thread.snapshot(thread_id).items, &(&1["type"] == "agentMessage"))["text"] ==
               "hi there"

      # simulate a BEAM-side loss of the projection, then resume
      ThreadState.stop(thread_id)
      assert {:ok, ^thread_id} = Thread.resume(thread_id, conn: conn)
      snapshot = Thread.snapshot(thread_id)

      assert Enum.any?(
               snapshot.items,
               &(&1["type"] == "agentMessage" and &1["text"] == "hi there")
             )

      assert snapshot.thread["id"] == thread_id
    end

    test "interrupt ends the turn as interrupted", %{conn: conn} do
      {:ok, thread_id} = Thread.start(cwd: "/", conn: conn)
      Thread.subscribe(thread_id)
      {:ok, turn_id} = Thread.send(thread_id, "stall", conn: conn)
      assert_receive {:codex, _, "item/agentMessage/delta", %{"delta" => "c"}}, 10_000

      assert :ok = Thread.interrupt(thread_id, turn_id, conn: conn)

      assert_receive {:codex, _, "turn/completed", %{"turn" => %{"status" => "interrupted"}}},
                     5_000
    end

    test "a builtin tool round-trips through the connection (thread_status sees its own thread)",
         %{conn: conn} do
      {:ok, thread_id} = Thread.start(cwd: "/", conn: conn)
      Thread.subscribe(thread_id)
      {:ok, _} = Thread.send(thread_id, "call builtin.thread_status {}", conn: conn)
      assert_receive {:codex, _, "turn/completed", _}, 10_000
      text = Enum.find(Thread.snapshot(thread_id).items, &(&1["type"] == "agentMessage"))["text"]
      assert text =~ "tool true:"
      assert text =~ "thread: #{thread_id}"
      assert text =~ "userMessage: 1"
    end

    test "respond/3 answers a pending approval by id", %{conn: conn} do
      {:ok, thread_id} = Thread.start(cwd: "/", conn: conn)
      Thread.subscribe(thread_id)
      {:ok, _} = Thread.send(thread_id, "approve make", conn: conn)

      assert_receive {:codex, _, "item/commandExecution/requestApproval",
                      %{"requestId" => request_id}},
                     10_000

      assert :ok = Thread.respond(request_id, :accept, conn: conn)

      assert_receive {:codex, _, "turn/completed", %{"turn" => %{"status" => "completed"}}},
                     10_000

      assert Enum.any?(Thread.snapshot(thread_id).items, &(&1["type"] == "commandExecution"))
    end
  end
end
