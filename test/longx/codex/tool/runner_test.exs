defmodule Longx.Codex.Tool.RunnerTest do
  use ExUnit.Case, async: true

  alias Longx.Codex.Tool.Runner

  defp params(ns, tool, args, extra \\ %{}) do
    Map.merge(
      %{
        "tool" => tool,
        "namespace" => ns,
        "arguments" => args,
        "callId" => "call_1",
        "threadId" => "thr_1",
        "turnId" => "turn_1"
      },
      extra
    )
  end

  test "a successful text result becomes one inputText item" do
    assert %{
             "success" => true,
             "contentItems" => [%{"type" => "inputText", "text" => "echo: hi"}]
           } =
             Runner.run(params("test", "echo", %{"message" => "hi"}))
  end

  test "mixed content is mapped item by item" do
    assert %{
             "success" => true,
             "contentItems" => [
               %{"type" => "inputText", "text" => "here"},
               %{"type" => "inputImage", "imageUrl" => "https://x/y.png"}
             ]
           } =
             Runner.run(params("test", "failing", %{"picture" => true}))
  end

  test "{:error, message} is a failed call the model can read" do
    assert %{"success" => false, "contentItems" => [%{"type" => "inputText", "text" => "nope"}]} =
             Runner.run(params("test", "failing", %{}))
  end

  test "arguments are validated against the schema and the model is told how to fix them" do
    %{"success" => false, "contentItems" => [%{"text" => text}]} =
      Runner.run(params("test", "echo", %{"message" => 42}))

    assert text =~ "invalid arguments for test.echo"
    assert text =~ "#/message"
    assert text =~ "String"
    assert text =~ ~s("required")

    %{"success" => false, "contentItems" => [%{"text" => text}]} =
      Runner.run(params("test", "echo", %{}))

    assert text =~ "message"
    assert text =~ "required"
  end

  test "non-object arguments (a JSON string, null) are rejected the same way" do
    %{"success" => false, "contentItems" => [%{"text" => text}]} =
      Runner.run(params("test", "echo", "just text"))

    assert text =~ "invalid arguments"
    %{"success" => false} = Runner.run(params("test", "echo", nil))
  end

  test "an unknown tool is a failed call, not a crash" do
    %{"success" => false, "contentItems" => [%{"text" => text}]} =
      Runner.run(params("test", "missing", %{}))

    assert text =~ "unknown tool test.missing"
    assert text =~ "test.echo"
  end

  test "a missing namespace means builtin" do
    assert %{"success" => true, "contentItems" => [%{"text" => "yo"}]} =
             Runner.run(params(nil, "echo", %{"message" => "yo"}) |> Map.delete("namespace"))
  end

  test "a crashing tool is reported, with the exception message" do
    %{"success" => false, "contentItems" => [%{"text" => text}]} =
      Runner.run(params("test", "boom", %{}))

    assert text =~ "test.boom crashed"
    assert text =~ "kaboom"
  end

  test "a tool exceeding its timeout is killed and reported" do
    started = System.monotonic_time(:millisecond)

    %{"success" => false, "contentItems" => [%{"text" => text}]} =
      Runner.run(params("test", "slow", %{}))

    assert text =~ "timed out after 200ms"
    assert System.monotonic_time(:millisecond) - started < 2_000
  end

  test "the context carries the call ids and a lazy thread snapshot" do
    thread_id = "thr-#{System.unique_integer([:positive])}"
    {:ok, _} = Longx.Codex.ThreadState.ensure(thread_id)

    Longx.Codex.ThreadState.ingest(thread_id, "thread/started", %{
      "thread" => %{"id" => thread_id, "cwd" => "/work"}
    })

    Longx.Codex.ThreadState.ingest(thread_id, "item/started", %{
      "turnId" => "t",
      "item" => %{"id" => "u", "type" => "userMessage"}
    })

    Longx.Codex.ThreadState.subscribe(thread_id)
    assert_receive {:codex, 2, _, _}

    %{"success" => true, "contentItems" => [%{"text" => text}]} =
      Runner.run(
        params("test", "contextual", %{}, %{
          "threadId" => thread_id,
          "turnId" => "turn_9",
          "callId" => "call_9"
        })
      )

    assert text == "thread=#{thread_id} turn=turn_9 call=call_9 cwd=/work items=1"
  end

  test "telemetry start/stop events carry the tool identity" do
    ref = make_ref()
    parent = self()

    :telemetry.attach_many(
      "runner-test-#{inspect(ref)}",
      [[:longx, :codex, :tool, :start], [:longx, :codex, :tool, :stop]],
      fn event, measurements, meta, _ -> send(parent, {ref, event, measurements, meta}) end,
      nil
    )

    Runner.run(params("test", "echo", %{"message" => "t"}))

    assert_receive {^ref, [:longx, :codex, :tool, :start], _,
                    %{namespace: "test", name: "echo", thread_id: "thr_1"}}

    assert_receive {^ref, [:longx, :codex, :tool, :stop], %{duration: d},
                    %{namespace: "test", name: "echo", success: true}}
                   when is_integer(d)

    :telemetry.detach("runner-test-#{inspect(ref)}")
  end
end
