defmodule Longx.Codex.AutoReviewIntegrationTest do
  @moduledoc """
  codex's automatic approval review (Guardian, `approvals_reviewer =
  "auto_review"`) against the real binary through our gateway: a command
  asking for a directory is judged by a reviewer sub-session on the same
  model — a `Bypass` plays both the agent and the reviewer — instead of a
  card; a denial can be overridden by the person
  (`thread/approveGuardianDeniedAction`), which the model sees as a
  developer note on its next request.
  """
  use Longx.DataCase, async: false

  import Longx.Test.CodexHarness

  alias Longx.Codex.{Connection, Thread, ThreadState}
  alias Longx.Test.ResponsesFixture

  @moduletag :integration

  setup do
    Ash.bulk_destroy!(Longx.AI.Model, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(Longx.AI.Provider, :destroy, %{}, authorize?: false)
    bypass = Bypass.open()

    {:ok, provider} =
      Longx.AI.create_provider(%{
        name: "Fake",
        slug: "fake",
        base_url: "http://localhost:#{bypass.port}/v1",
        api_key: "k"
      })

    {:ok, model} =
      Longx.AI.create_model(%{
        name: "Fake",
        upstream_id: "fake-model",
        provider_id: provider.id,
        context_window: 128_000
      })

    {:ok, _} = Longx.AI.make_default_model(model)
    %{bypass: bypass, gateway_url: serve_endpoint!()}
  end

  defp send_sse(conn, frames) do
    conn =
      conn |> Plug.Conn.put_resp_content_type("text/event-stream") |> Plug.Conn.send_chunked(200)

    Enum.reduce(frames, conn, fn frame, conn ->
      {:ok, conn} = Plug.Conn.chunk(conn, frame)
      conn
    end)
  end

  # the reviewer's request is a session of its own: Guardian's base
  # instructions (not codex's coding prompt) and a strict-JSON verdict
  defp reviewer?(body), do: String.starts_with?(body["instructions"] || "", "You are judging")

  # the agent asks for the home directory once, then reports; the reviewer
  # answers `verdict`
  defp script(bypass, test_pid, probe, verdict) do
    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      send(test_pid, {:request, body})

      cond do
        reviewer?(body) ->
          send_sse(
            conn,
            ResponsesFixture.assistant_message(
              ~s({"outcome":"#{verdict}","risk_level":"low","rationale":"a probe file"})
            )
          )

        # a fresh turn (the person spoke last): ask; after the call's output: report
        List.last(body["input"])["type"] != "function_call_output" ->
          send_sse(
            conn,
            ResponsesFixture.function_call("exec_command", nil, %{
              cmd: "touch #{probe} && echo written",
              sandbox_permissions: "with_additional_permissions",
              additional_permissions: %{file_system: %{write: [Path.dirname(probe)]}},
              justification: "write a probe file in the home"
            })
          )

        true ->
          send_sse(conn, ResponsesFixture.assistant_message("done"))
      end
    end)
  end

  defp reviewed_thread!(conn, home) do
    params =
      Thread.start_params(
        cwd: home.dir,
        sandbox: :workspace_write,
        approval_policy: :on_request,
        auto_review: true,
        tools: []
      )

    {:ok, %{"thread" => %{"id" => thread_id}}} = Connection.request(conn, "thread/start", params)
    {:ok, _} = ThreadState.ensure(thread_id)
    :ok = Thread.subscribe(thread_id)
    thread_id
  end

  defp probe_path,
    do: Path.join(System.user_home!(), "longx-review-probe-#{System.unique_integer([:positive])}")

  test "allowed: the reviewer runs on the thread's model through the gateway, no card, the command runs with the grant",
       %{bypass: bypass, gateway_url: gateway_url} do
    probe = probe_path()
    on_exit(fn -> File.rm(probe) end)
    script(bypass, self(), probe, "allow")

    home = prepare_home!(gateway_url)
    conn = start_connection!(home)
    thread_id = reviewed_thread!(conn, home)
    {:ok, _} = Thread.send(thread_id, "go", conn: conn)

    assert_receive {:codex, _, "item/autoApprovalReview/started",
                    %{"reviewId" => review_id, "review" => %{"status" => "inProgress"}}},
                   30_000

    assert_receive {:codex, _, "item/autoApprovalReview/completed",
                    %{"reviewId" => ^review_id, "review" => review, "action" => action}},
                   30_000

    assert review["status"] == "approved"
    assert review["riskLevel"] == "low"
    assert review["rationale"] == "a probe file"
    assert action["type"] == "command"
    assert action["command"] =~ "touch #{probe}"

    assert_receive {:codex, _, "turn/completed", _}, 60_000
    refute_received {:codex, _, "item/commandExecution/requestApproval", _}
    assert File.regular?(probe)

    # the review is an item of the view naming the command it judged (which
    # codex starts first: the row shows the verdict on the command)
    items = Thread.snapshot(thread_id).items

    assert [%{"targetItemId" => target}] =
             Enum.filter(items, &(&1["type"] == "autoApprovalReview"))

    assert [%{"id" => ^target, "status" => "completed"}] =
             Enum.filter(items, &(&1["type"] == "commandExecution"))

    # the reviewer's request went to the gateway as its own session
    assert_receive {:request, %{"instructions" => "You are judging" <> _ = _, "input" => input}}
    refute Enum.any?(input, &(&1["type"] == "function_call_output"))
  end

  test "denied: the command does not run, the model is told to stop; the person overrides and the model sees the approval",
       %{bypass: bypass, gateway_url: gateway_url} do
    probe = probe_path()
    on_exit(fn -> File.rm(probe) end)
    script(bypass, self(), probe, "deny")

    home = prepare_home!(gateway_url)
    conn = start_connection!(home)
    thread_id = reviewed_thread!(conn, home)
    {:ok, _} = Thread.send(thread_id, "go", conn: conn)

    assert_receive {:codex, _, "item/autoApprovalReview/completed",
                    %{"reviewId" => review_id, "review" => %{"status" => "denied"}}},
                   30_000

    assert_receive {:codex, _, "turn/completed", _}, 60_000
    refute File.regular?(probe)

    # what the model was told
    assert_receive {:request, %{"input" => input}} when length(input) > 3
    output = Enum.find_value(input, &(&1["type"] == "function_call_output" && &1["output"]))
    assert output =~ "rejected due to unacceptable risk"
    assert output =~ "request user input"

    assert :ok = Thread.approve_denied_review(thread_id, review_id, conn: conn)

    assert_receive {:codex, _, "item/autoApprovalReview/userApproved",
                    %{"reviewId" => ^review_id}}

    assert [%{"userApproved" => true}] =
             Enum.filter(Thread.snapshot(thread_id).items, &(&1["type"] == "autoApprovalReview"))

    # the next turn carries the approval as a developer note
    {:ok, _} = Thread.send(thread_id, "continue", conn: conn)
    assert_receive {:codex, _, "turn/completed", _}, 60_000

    assert_receive {:request, %{"input" => input}} when length(input) > 5
    texts = for %{"role" => "developer", "content" => c} <- input, %{"text" => t} <- c, do: t
    assert Enum.any?(texts, &(&1 =~ "manually approved" and &1 =~ "touch #{probe}"))
  end

  test "a request_permissions call is reviewed too; its denial can be overridden (core takes the permissions in its own shape)",
       %{bypass: bypass, gateway_url: gateway_url} do
    test_pid = self()

    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      outputs = for %{"type" => "function_call_output", "output" => o} <- body["input"], do: o
      send(test_pid, {:request, body})

      cond do
        reviewer?(body) ->
          send_sse(
            conn,
            ResponsesFixture.assistant_message(
              ~s({"outcome":"deny","risk_level":"high","rationale":"the whole home"})
            )
          )

        outputs == [] ->
          send_sse(
            conn,
            ResponsesFixture.function_call("request_permissions", nil, %{
              permissions: %{
                file_system: %{write: [System.user_home!()]},
                network: %{enabled: true}
              },
              reason: "install into the home"
            })
          )

        true ->
          send_sse(conn, ResponsesFixture.assistant_message("done"))
      end
    end)

    home = prepare_home!(gateway_url)
    conn = start_connection!(home)
    thread_id = reviewed_thread!(conn, home)
    {:ok, _} = Thread.send(thread_id, "go", conn: conn)

    assert_receive {:codex, _, "item/autoApprovalReview/completed",
                    %{
                      "reviewId" => review_id,
                      "review" => %{"status" => "denied"},
                      "action" => action
                    }},
                   30_000

    assert action["type"] == "requestPermissions"

    assert %{"fileSystem" => %{"write" => [_]}, "network" => %{"enabled" => true}} =
             action["permissions"]

    refute_received {:codex, _, "item/permissions/requestApproval", _}
    assert_receive {:codex, _, "turn/completed", _}, 60_000

    assert :ok = Thread.approve_denied_review(thread_id, review_id, conn: conn)

    assert_receive {:codex, _, "item/autoApprovalReview/userApproved",
                    %{"reviewId" => ^review_id}}
  end

  test "全部放行 (auto_accept): no reviewer, no card — Longx accepts the request and the command runs; switching the reviewer mid-thread is a settings update codex takes",
       %{bypass: bypass, gateway_url: gateway_url} do
    probe = probe_path()
    on_exit(fn -> File.rm(probe) end)
    script(bypass, self(), probe, "deny")

    home = prepare_home!(gateway_url)
    conn = start_connection!(home)

    params =
      Thread.start_params(
        cwd: home.dir,
        sandbox: :workspace_write,
        approval_policy: :auto_accept,
        auto_review: true,
        tools: []
      )

    {:ok, %{"thread" => %{"id" => thread_id}}} = Connection.request(conn, "thread/start", params)
    ThreadState.Store.set_auto_accept(thread_id, true)
    {:ok, _} = ThreadState.ensure(thread_id)
    :ok = Thread.subscribe(thread_id)
    {:ok, _} = Thread.send(thread_id, "go", conn: conn)

    assert_receive {:codex, _, "turn/completed", _}, 60_000
    refute_received {:codex, _, "item/commandExecution/requestApproval", _}
    refute_received {:codex, _, "item/autoApprovalReview/started", _}
    assert File.regular?(probe)
    # the reviewer was never asked (its request would have been denied)
    refute_received {:request, %{"instructions" => "You are judging" <> _}}

    # back to the reviewer for the turns after: the next request is reviewed (and denied)
    assert :ok = Thread.update_settings(thread_id, approvals_reviewer: :auto_review, conn: conn)
    ThreadState.Store.set_auto_accept(thread_id, false)
    File.rm(probe)
    {:ok, _} = Thread.send(thread_id, "again", conn: conn)

    assert_receive {:codex, _, "item/autoApprovalReview/completed",
                    %{"review" => %{"status" => "denied"}}},
                   30_000

    assert_receive {:codex, _, "turn/completed", _}, 60_000
    refute File.regular?(probe)
  end

  test "a reviewer model of its own: the review runs on that model at the pinned level, the agent stays on the thread's",
       %{bypass: bypass, gateway_url: gateway_url} do
    {:ok, provider} = Longx.AI.get_provider_by_slug("fake")

    {:ok, _} =
      Longx.AI.create_model(%{
        name: "Review",
        upstream_id: "fake-review",
        provider_id: provider.id,
        context_window: 64_000,
        reasoning_levels: ["low", "high"]
      })

    :ok = Longx.AI.set_review_model("fake-review", "high")

    probe = probe_path()
    on_exit(fn -> File.rm(probe) end)
    script(bypass, self(), probe, "allow")

    home = prepare_home!(gateway_url)
    conn = start_connection!(home)
    thread_id = reviewed_thread!(conn, home)
    {:ok, _} = Thread.send(thread_id, "go", conn: conn)

    assert_receive {:codex, _, "item/autoApprovalReview/completed",
                    %{"review" => %{"status" => "approved"}}},
                   30_000

    assert_receive {:codex, _, "turn/completed", _}, 60_000
    assert File.regular?(probe)

    assert_receive {:request, %{"instructions" => "You are judging" <> _} = review}
    assert review["model"] == "fake-review"
    assert review["reasoning"]["effort"] == "high"

    assert_receive {:request, %{"instructions" => "You are a coding agent" <> _} = agent}
    assert agent["model"] == "fake-model"
  end
end
