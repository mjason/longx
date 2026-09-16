defmodule Longx.Codex.ThreadTest do
  use Longx.DataCase, async: false

  alias Longx.Codex.{Connection, Thread, ThreadState}

  @fake Path.expand("test/support/fake_app_server.exs")

  setup do
    Ash.bulk_destroy!(Longx.AI.Tool, :destroy, %{}, authorize?: false)
    :ok
  end

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
                 "historyMode" => "paginated",
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
               %{
                 "cwd" => "/p",
                 "historyMode" => "paginated",
                 "approvalPolicy" => "on-request",
                 "sandbox" => "workspace-write"
               }

      assert Thread.start_params(
               cwd: "/p",
               sandbox: :danger_full_access,
               approval_policy: :untrusted
             )["sandbox"] == "danger-full-access"
    end

    test "tools: [\"ns.name\"] declares exactly those; tools: [] nothing" do
      refute Map.has_key?(Thread.start_params(cwd: "/p", tools: []), "dynamicTools")

      [only] = Thread.start_params(cwd: "/p", tools: ["builtin.echo"])["dynamicTools"]
      assert only["name"] == "builtin"
      assert Enum.map(only["tools"], & &1["name"]) == ["echo"]

      names =
        Thread.start_params(cwd: "/p", tools: ["builtin.echo", "test.echo"])["dynamicTools"]
        |> Enum.map(& &1["name"])

      assert names == ["builtin", "test"]
    end

    test "without tools: the globally enabled set from the DB is used (the memory tools by default)" do
      [memory] = Thread.start_params(cwd: "/p")["dynamicTools"]
      assert memory["name"] == "memory"
      assert Enum.map(memory["tools"], & &1["name"]) |> Enum.sort() == ["note", "read", "search"]

      {:ok, _} = Longx.AI.enable_tool("builtin.thread_status")
      namespaces = Thread.start_params(cwd: "/p")["dynamicTools"]
      builtin = Enum.find(namespaces, &(&1["name"] == "builtin"))
      assert Enum.map(builtin["tools"], & &1["name"]) == ["thread_status"]
    end

    test "model: sets codex's per-thread model (a Longx.AI.Model slug)" do
      assert Thread.start_params(cwd: "/p", tools: [], model: "deepseek-flash")["model"] ==
               "deepseek-flash"

      refute Map.has_key?(Thread.start_params(cwd: "/p", tools: []), "model")
    end

    test "web_search: sets the thread's search mode as config overrides (dotted keys, like -c)" do
      assert Thread.start_params(cwd: "/p", tools: [], web_search: :hosted)["config"] ==
               %{"web_search" => "live", "features.standalone_web_search" => false}

      assert Thread.start_params(cwd: "/p", tools: [], web_search: :standalone)["config"] ==
               %{"web_search" => "live", "features.standalone_web_search" => true}

      assert Thread.start_params(cwd: "/p", tools: [], web_search: :disabled)["config"] ==
               %{"web_search" => "disabled", "features.standalone_web_search" => false}

      refute Map.has_key?(Thread.start_params(cwd: "/p", tools: []), "config")
    end

    test "model settings become codex config overrides next to the context window" do
      config =
        Thread.start_params(
          cwd: "/p",
          tools: [],
          model: "gpt-x",
          model_context_window: 400_000,
          reasoning_effort: "high",
          reasoning_summary: :detailed
        )["config"]

      assert config == %{
               "model_context_window" => 400_000,
               "model_reasoning_effort" => "high",
               "model_reasoning_summary" => "detailed"
             }
    end

    test "start_params/1: multi_agent turns codex's sub-agent tools on for the thread" do
      config = Thread.start_params(cwd: "/p", tools: [], multi_agent: true)["config"]
      assert config["features.multi_agent_v2"] == true

      refute Map.has_key?(
               Thread.start_params(cwd: "/p", tools: [])["config"] || %{},
               "features.multi_agent_v2"
             )

      assert Thread.start_params(cwd: "/p", tools: [], multi_agent: false)["config"][
               "features.multi_agent_v2"
             ] == false
    end

    test "start_params/1: auto_review puts codex's Guardian reviewer on the thread (approvals_reviewer)" do
      assert Thread.start_params(cwd: "/p", tools: [], auto_review: true)["config"][
               "approvals_reviewer"
             ] == "auto_review"

      assert Thread.start_params(cwd: "/p", tools: [], auto_review: false)["config"][
               "approvals_reviewer"
             ] == "user"

      refute Map.has_key?(
               Thread.start_params(cwd: "/p", tools: [])["config"] || %{},
               "approvals_reviewer"
             )
    end

    test "guardian_event/1: the stored review item back in codex's core shape (snake_case, its enums too)" do
      item = %{
        "id" => "rev-1",
        "type" => "autoApprovalReview",
        "turnId" => "turn-1",
        "targetItemId" => "call_1",
        "action" => %{
          "type" => "command",
          "source" => "unifiedExec",
          "command" => "ls",
          "cwd" => "/p"
        },
        "review" => %{
          "status" => "denied",
          "riskLevel" => "high",
          "userAuthorization" => "unknown",
          "rationale" => "why"
        },
        "decisionSource" => "agent",
        "startedAtMs" => 10,
        "completedAtMs" => 20
      }

      assert Thread.guardian_event(item) == %{
               "id" => "rev-1",
               "turn_id" => "turn-1",
               "target_item_id" => "call_1",
               "status" => "denied",
               "risk_level" => "high",
               "user_authorization" => "unknown",
               "rationale" => "why",
               "decision_source" => "agent",
               "started_at_ms" => 10,
               "completed_at_ms" => 20,
               "action" => %{
                 "type" => "command",
                 "source" => "unified_exec",
                 "command" => "ls",
                 "cwd" => "/p"
               }
             }

      # a permissions request: nested keys snake_cased; codex's core file_system
      # is *either* the legacy read/write lists *or* entries (the v2 shape
      # carries both when the lists suffice, and core refuses the mix)
      event = fn fs ->
        Thread.guardian_event(%{
          "id" => "r",
          "review" => %{"status" => "denied"},
          "action" => %{
            "type" => "requestPermissions",
            "reason" => "r",
            "permissions" => %{"fileSystem" => fs, "network" => %{"enabled" => true}}
          }
        })["action"]
      end

      assert %{
               "type" => "request_permissions",
               "reason" => "r",
               "permissions" => %{
                 "file_system" => %{"write" => ["/x"]},
                 "network" => %{"enabled" => true}
               }
             } =
               event.(%{
                 "read" => nil,
                 "write" => ["/x"],
                 "entries" => [
                   %{"access" => "write", "path" => %{"type" => "path", "path" => "/x"}}
                 ]
               })

      assert %{"permissions" => %{"file_system" => fs}} =
               event.(%{
                 "read" => nil,
                 "write" => nil,
                 "globScanMaxDepth" => 2,
                 "entries" => [
                   %{
                     "access" => "read",
                     "path" => %{"type" => "special", "value" => "projectRoots"}
                   }
                 ]
               })

      assert fs == %{
               "glob_scan_max_depth" => 2,
               "entries" => [
                 %{
                   "access" => "read",
                   "path" => %{"type" => "special", "value" => "project_roots"}
                 }
               ]
             }
    end

    test "approval_policy: :auto_accept is codex's on-request with no reviewer — Longx answers the requests itself" do
      params =
        Thread.start_params(
          cwd: "/p",
          tools: [],
          approval_policy: :auto_accept,
          auto_review: true
        )

      assert params["approvalPolicy"] == "on-request"
      assert params["config"]["approvals_reviewer"] == "user"

      assert Thread.turn_params("t", "go", approval_policy: :auto_accept)["approvalPolicy"] ==
               "on-request"
    end

    test "start_params/1: developer instructions ride on thread/start when given" do
      assert Thread.start_params(cwd: "/p", tools: [], developer_instructions: "remember X")[
               "developerInstructions"
             ] == "remember X"

      refute Map.has_key?(Thread.start_params(cwd: "/p", tools: []), "developerInstructions")
    end

    test "turn_params/3: text input, optional model / effort / summary for this turn onwards" do
      assert Thread.turn_params("t", "hi", []) ==
               %{"threadId" => "t", "input" => [%{"type" => "text", "text" => "hi"}]}

      params = Thread.turn_params("t", "hi", model: "gpt-x", effort: "low", summary: :none)
      assert params["model"] == "gpt-x"
      assert params["effort"] == "low"
      assert params["summary"] == "none"
    end

    test "turn_params/3: images ride along as image inputs after the text" do
      params = Thread.turn_params("t", "look", images: ["data:image/png;base64,AAAA"])

      assert params["input"] == [
               %{"type" => "text", "text" => "look"},
               %{"type" => "image", "url" => "data:image/png;base64,AAAA"}
             ]
    end

    test "review_params/2 names the target and delivers the review into the thread" do
      assert Thread.review_params("t", :uncommitted) == %{
               "threadId" => "t",
               "target" => %{"type" => "uncommittedChanges"},
               "delivery" => "inline"
             }

      assert Thread.review_params("t", {:commit, "abc"})["target"] ==
               %{"type" => "commit", "sha" => "abc"}

      assert Thread.review_params("t", {:base_branch, "main"})["target"] ==
               %{"type" => "baseBranch", "branch" => "main"}

      assert Thread.review_params("t", {:custom, "check the tests"})["target"] ==
               %{"type" => "custom", "instructions" => "check the tests"}
    end

    test "turn_params/3: the access mode switches for this turn and the ones after" do
      params =
        Thread.turn_params("t", "hi",
          sandbox: :workspace_write,
          approval_policy: :never,
          network_access: true
        )

      assert params["approvalPolicy"] == "never"
      assert params["sandboxPolicy"] == %{"type" => "workspaceWrite", "networkAccess" => true}

      assert Thread.turn_params("t", "hi", sandbox: :read_only)["sandboxPolicy"] ==
               %{"type" => "readOnly"}

      assert Thread.turn_params("t", "hi", sandbox: :danger_full_access)["sandboxPolicy"] ==
               %{"type" => "dangerFullAccess"}

      # nothing given → nothing sent (the thread keeps what it has)
      refute Map.has_key?(Thread.turn_params("t", "hi", []), "sandboxPolicy")
    end

    test "fork_params/2 carries the same model settings as a start" do
      params =
        Thread.fork_params("t",
          last_turn_id: "u1",
          model: "gpt-x",
          model_context_window: 400_000,
          web_search: :hosted
        )

      assert params["threadId"] == "t"
      assert params["lastTurnId"] == "u1"
      assert params["model"] == "gpt-x"
      assert params["config"]["model_context_window"] == 400_000
      assert params["config"]["web_search"] == "live"

      assert Thread.fork_params("t", []) == %{"threadId" => "t"}
    end

    test "writable_roots: extra directories (and device nodes) the workspace-write sandbox may write" do
      roots = ["/home/x/.cache", "/dev/nvidia0"]

      assert Thread.start_params(cwd: "/p", tools: [], writable_roots: roots)["config"] ==
               %{"sandbox_workspace_write.writable_roots" => roots}

      # none: no key (and no config at all here)
      assert Thread.start_params(cwd: "/p", tools: [], writable_roots: [])["config"] == nil

      # on a turn that changes the mode the whole policy goes, roots included
      assert Thread.turn_params("t", "hi",
               sandbox: :workspace_write,
               network_access: true,
               writable_roots: roots
             )["sandboxPolicy"] ==
               %{"type" => "workspaceWrite", "networkAccess" => true, "writableRoots" => roots}

      assert Thread.turn_params("t", "hi", sandbox: :read_only, writable_roots: roots)[
               "sandboxPolicy"
             ] == %{"type" => "readOnly"}
    end

    test "network_access: true opens the network inside the workspace-write sandbox" do
      assert Thread.start_params(cwd: "/p", tools: [], network_access: true)["config"] ==
               %{"sandbox_workspace_write.network_access" => true}

      refute Map.has_key?(
               Thread.start_params(cwd: "/p", tools: [], network_access: false),
               "config"
             )
    end

    test "threads are always paginated (thread/revert needs it)" do
      assert Thread.start_params(cwd: "/p", tools: [])["historyMode"] == "paginated"
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

    test "resume carries the thread's access mode and developer instructions — codex would otherwise fall back to its defaults",
         %{conn: conn} do
      {:ok, thread_id} = Thread.start(cwd: "/p", tools: [], conn: conn)

      assert {:ok, ^thread_id} =
               Thread.resume(thread_id,
                 conn: conn,
                 sandbox: :danger_full_access,
                 approval_policy: :never,
                 developer_instructions: "notes"
               )

      assert {:ok, %{"thread" => %{"resumeParams" => params}}} =
               Connection.request(conn, "thread/read", %{"threadId" => thread_id})

      assert %{
               "sandbox" => "danger-full-access",
               "approvalPolicy" => "never",
               "developerInstructions" => "notes"
             } = params

      # nothing given: nothing sent (codex keeps its own)
      {:ok, _} = Thread.resume(thread_id, conn: conn)

      assert {:ok, %{"thread" => %{"resumeParams" => params}}} =
               Connection.request(conn, "thread/read", %{"threadId" => thread_id})

      refute Map.has_key?(params, "sandbox")
      refute Map.has_key?(params, "approvalPolicy")
    end

    test "resume carries the model's config overrides like start does", %{conn: conn} do
      {:ok, thread_id} = Thread.start(cwd: "/", conn: conn)
      ThreadState.stop(thread_id)

      assert {:ok, ^thread_id} =
               Thread.resume(thread_id,
                 conn: conn,
                 model_context_window: 1_000_000,
                 reasoning_effort: "high",
                 web_search: :standalone
               )

      assert {:ok, %{"thread" => %{"resumeParams" => %{"config" => config}}}} =
               Connection.request(conn, "thread/read", %{"threadId" => thread_id})

      assert config["model_context_window"] == 1_000_000
      assert config["model_reasoning_effort"] == "high"
      assert config["web_search"] == "live"
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
      {:ok, thread_id} = Thread.start(cwd: "/", tools: ["builtin.thread_status"], conn: conn)
      Thread.subscribe(thread_id)
      {:ok, _} = Thread.send(thread_id, "call builtin.thread_status {}", conn: conn)
      assert_receive {:codex, _, "turn/completed", _}, 10_000
      text = Enum.find(Thread.snapshot(thread_id).items, &(&1["type"] == "agentMessage"))["text"]
      assert text =~ "tool true:"
      assert text =~ "thread: #{thread_id}"
      assert text =~ "userMessage: 1"
    end

    test "revert/3 drops a turn and everything after it, in codex and in the ThreadState", %{
      conn: conn
    } do
      {:ok, thread_id} = Thread.start(cwd: "/", tools: [], conn: conn)
      Thread.subscribe(thread_id)
      {:ok, t1} = Thread.send(thread_id, "say one", conn: conn)
      assert_receive {:codex, _, "turn/completed", %{"turn" => %{"id" => ^t1}}}, 10_000
      {:ok, t2} = Thread.send(thread_id, "say two", conn: conn)
      assert_receive {:codex, _, "turn/completed", %{"turn" => %{"id" => ^t2}}}, 10_000

      assert :ok = Thread.revert(thread_id, t2, conn: conn)

      assert_receive {:codex, seq, "thread/reverted",
                      %{"threadId" => ^thread_id, "turnIds" => [^t2]}},
                     5_000

      assert is_integer(seq)

      snapshot = Thread.snapshot(thread_id)
      assert Enum.all?(snapshot.items, &(&1["turnId"] == t1))

      {:ok, read} =
        Connection.request(conn, "thread/read", %{"threadId" => thread_id, "includeTurns" => true})

      assert Enum.map(read["thread"]["turns"], & &1["id"]) == [t1]
    end

    test "fork/3 branches the history into a new thread", %{conn: conn} do
      {:ok, thread_id} = Thread.start(cwd: "/", tools: [], conn: conn)
      Thread.subscribe(thread_id)
      {:ok, t1} = Thread.send(thread_id, "say one", conn: conn)
      assert_receive {:codex, _, "turn/completed", %{"turn" => %{"id" => ^t1}}}, 10_000
      {:ok, t2} = Thread.send(thread_id, "say two", conn: conn)
      assert_receive {:codex, _, "turn/completed", %{"turn" => %{"id" => ^t2}}}, 10_000

      assert {:ok, forked} = Thread.fork(thread_id, last_turn_id: t1, model: "glm-5", conn: conn)
      refute forked == thread_id

      {:ok, read} =
        Connection.request(conn, "thread/read", %{"threadId" => forked, "includeTurns" => true})

      assert Enum.map(read["thread"]["turns"], & &1["id"]) == [t1]
      # the original is untouched
      {:ok, read} =
        Connection.request(conn, "thread/read", %{"threadId" => thread_id, "includeTurns" => true})

      assert Enum.map(read["thread"]["turns"], & &1["id"]) == [t1, t2]
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

  describe "auto_accept (全部放行)" do
    setup do
      %{conn: start_supervised!({Connection, name: nil, command: ["elixir", @fake], env: []})}
    end

    test "start / send / resume with the policy set the thread's flag, and Longx answers the approval on its own",
         %{conn: conn} do
      {:ok, thread_id} = Thread.start(cwd: "/", approval_policy: :auto_accept, conn: conn)
      assert ThreadState.Store.auto_accept?(thread_id)
      Thread.subscribe(thread_id)

      {:ok, _} = Thread.send(thread_id, "approve make", conn: conn)

      assert_receive {:codex, _, "turn/completed", %{"turn" => %{"status" => "completed"}}},
                     10_000

      refute_received {:codex, _, "item/commandExecution/requestApproval", _}
      assert Enum.any?(Thread.snapshot(thread_id).items, &(&1["type"] == "commandExecution"))

      # a turn back on on-request clears it; a resume with the policy sets it again
      {:ok, _} = Thread.send(thread_id, "say hi", approval_policy: :on_request, conn: conn)
      refute ThreadState.Store.auto_accept?(thread_id)
      assert_receive {:codex, _, "turn/completed", _}, 10_000
      {:ok, _} = Thread.resume(thread_id, cwd: "/", approval_policy: :auto_accept, conn: conn)
      assert ThreadState.Store.auto_accept?(thread_id)
    end

    test "update_settings/2 changes the reviewer of a running thread (thread/settings/update)", %{
      conn: conn
    } do
      {:ok, thread_id} = Thread.start(cwd: "/", conn: conn)
      assert :ok = Thread.update_settings(thread_id, approvals_reviewer: :user, conn: conn)
      {:ok, read} = Connection.request(conn, "thread/read", %{"threadId" => thread_id})

      assert read["thread"]["settings"] == %{
               "threadId" => thread_id,
               "approvalsReviewer" => "user"
             }
    end
  end

  describe "approve_denied_review/2" do
    setup do
      %{conn: start_supervised!({Connection, name: nil, command: ["elixir", @fake], env: []})}
    end

    test "sends the denied review back as thread/approveGuardianDeniedAction and marks the item approved by the person",
         %{conn: conn} do
      {:ok, thread_id} = Thread.start(cwd: "/", conn: conn)
      Thread.subscribe(thread_id)
      # the review as codex reported it
      ThreadState.ingest(thread_id, "item/autoApprovalReview/completed", %{
        "threadId" => thread_id,
        "turnId" => "t1",
        "reviewId" => "rev-1",
        "action" => %{
          "type" => "command",
          "source" => "unifiedExec",
          "command" => "ls",
          "cwd" => "/"
        },
        "review" => %{"status" => "denied", "riskLevel" => "high", "rationale" => "no"},
        "startedAtMs" => 1
      })

      assert_receive {:codex, _, "item/autoApprovalReview/completed", _}, 5_000

      assert :ok = Thread.approve_denied_review(thread_id, "rev-1", conn: conn)

      assert_receive {:codex, _, "item/autoApprovalReview/userApproved",
                      %{"reviewId" => "rev-1"}},
                     5_000

      assert [%{"id" => "rev-1", "userApproved" => true}] =
               Enum.filter(
                 Thread.snapshot(thread_id).items,
                 &(&1["type"] == "autoApprovalReview")
               )

      # what the fake received
      {:ok, read} = Connection.request(conn, "thread/read", %{"threadId" => thread_id})

      assert [%{"id" => "rev-1", "status" => "denied", "action" => %{"source" => "unified_exec"}}] =
               read["thread"]["approvedGuardianEvents"]
    end

    test "a review that is not denied, or unknown, is refused", %{conn: conn} do
      {:ok, thread_id} = Thread.start(cwd: "/", conn: conn)
      assert {:error, :not_found} = Thread.approve_denied_review(thread_id, "nope", conn: conn)
    end
  end

  describe "answers follow what the request offers (pure)" do
    test "the approval policy is codex's own on-request: the model asks for permissions, codex never retries a denial on its own" do
      assert Thread.start_params(cwd: "/p", tools: [], approval_policy: :on_request)[
               "approvalPolicy"
             ] ==
               "on-request"

      assert Thread.turn_params("t", "hi", approval_policy: :on_request)["approvalPolicy"] ==
               "on-request"

      assert Thread.start_params(cwd: "/p", tools: [], approval_policy: :never)["approvalPolicy"] ==
               "never"
    end

    test "a command approval: accept_for_session becomes the execpolicy amendment when that is what is offered; decline → cancel" do
      offered = %{
        "availableDecisions" => [
          "accept",
          %{"acceptWithExecpolicyAmendment" => %{"execpolicy_amendment" => ["ls"]}},
          "cancel"
        ],
        "proposedExecpolicyAmendment" => ["ls"]
      }

      method = "item/commandExecution/requestApproval"

      assert Thread.decision_for(:accept_for_session, method, offered) ==
               %{
                 "decision" => %{
                   "acceptWithExecpolicyAmendment" => %{"execpolicy_amendment" => ["ls"]}
                 }
               }

      assert Thread.decision_for(:decline, method, offered) == %{"decision" => "cancel"}
      assert Thread.decision_for(:accept, method, offered) == %{"decision" => "accept"}
      # a request that lists nothing (older codex, tests): the plain words
      assert Thread.decision_for(:accept_for_session, method, %{}) == %{
               "decision" => "acceptForSession"
             }

      assert Thread.decision_for(:decline, method, %{}) == %{"decision" => "decline"}
    end

    test "a permissions request (request_permissions tool): accept grants what was asked for the turn, accept_for_session for the session, decline grants nothing" do
      method = "item/permissions/requestApproval"
      asked = %{"fileSystem" => %{"write" => ["/home/u"]}, "network" => %{"enabled" => true}}
      params = %{"permissions" => asked, "reason" => "x"}

      assert Thread.decision_for(:accept, method, params) == %{
               "permissions" => asked,
               "scope" => "turn"
             }

      assert Thread.decision_for(:accept_for_session, method, params) == %{
               "permissions" => asked,
               "scope" => "session"
             }

      assert Thread.decision_for(:decline, method, params) == %{
               "permissions" => %{},
               "scope" => "turn"
             }

      assert Thread.decision_for(:cancel, method, params) == %{
               "permissions" => %{},
               "scope" => "turn"
             }
    end
  end
end
