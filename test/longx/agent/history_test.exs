defmodule Longx.Agent.HistoryTest do
  use Longx.DataCase, async: false

  alias Longx.Agent.{Context, History, Step, Tool, Transcript}
  alias Longx.Agent.Plugs.History, as: HistoryPlug
  alias Longx.Projects
  alias Longx.Projects.Thread

  setup do
    project =
      Projects.create_project!(%{
        name: "History #{System.unique_integer([:positive])}",
        root_path: File.cwd!()
      })

    current = thread(project)
    %{project: project, current: current, ctx: context(current)}
  end

  defp thread(project, attrs \\ %{}) do
    Thread
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          project_id: project.id,
          kernel_thread_id: "history-#{Ash.UUID.generate()}",
          cwd: File.cwd!()
        },
        attrs
      )
    )
    |> Ash.create!()
  end

  defp context(row),
    do: %Context{thread_id: row.kernel_thread_id, project_id: row.project_id}

  defp append(thread, seq, kind, input, ui \\ nil) do
    Transcript.append!(%{
      thread_id: thread,
      turn_id: "turn-#{seq}",
      seq: seq,
      kind: kind,
      input: input,
      ui: ui
    })
  end

  defp message(thread, seq, text, kind \\ :user_message),
    do: append(thread, seq, kind, %{"content" => text})

  test "pre-compaction originals remain available, without changing the folded input", %{
    ctx: ctx
  } do
    message(ctx.thread_id, 1, "旧方案：保留 100%_ 原文")
    message(ctx.thread_id, 2, "计划运行测试", :agent_message)
    append(ctx.thread_id, 3, :compaction, %{"content" => "摘要"})
    message(ctx.thread_id, 4, "继续")
    before = ctx.thread_id |> Transcript.items!() |> Transcript.input()

    assert {:ok, %{matches: [hit]}} = History.search(%{"query" => "100%_"}, ctx)
    assert hit.seq == 1
    assert hit.role == "user"
    assert hit.turn_id == "turn-1"

    assert {:ok, %{entries: [%{text: "计划运行测试", role: "assistant"}]}} =
             History.read(%{"seq" => 2}, ctx)

    assert before == ctx.thread_id |> Transcript.items!() |> Transcript.input()
    assert length(Transcript.items!(ctx.thread_id)) == 4
    refute Longx.Agent.whereis(ctx.thread_id)
  end

  test "directory includes archived and child conversations and pages without waking them", %{
    project: project,
    current: current,
    ctx: ctx
  } do
    archived = thread(project, %{title: "旧讨论", status: :archived})
    child = thread(project, %{parent_thread_id: current.id, agent_path: "/root/reader"})
    message(archived.kernel_thread_id, 1, "旧讨论内容")
    message(child.kernel_thread_id, 1, "子会话内容")

    assert {:ok, first} = History.sessions(%{"limit" => 1}, ctx)
    assert length(first.sessions) == 1
    assert first.next_offset == 1
    assert {:ok, all} = History.sessions(%{}, ctx)
    assert Enum.any?(all.sessions, &(&1.status == :archived))
    assert Enum.any?(all.sessions, &(&1.parent_thread_id == current.id))

    for row <- [archived, child] do
      assert {:ok, %{entries: [_]}} =
               History.read(%{"thread_id" => row.kernel_thread_id}, ctx)

      refute Longx.Agent.whereis(row.kernel_thread_id)
    end
  end

  test "cross-project, unknown IDs and forged current project scope are refused", %{ctx: ctx} do
    # An existing directory distinct from the fixture's root.
    other =
      Projects.create_project!(%{
        name: "Other history",
        root_path: Path.join(File.cwd!(), "test")
      })

    row = thread(other)
    message(row.kernel_thread_id, 1, "private other project")

    for id <- [row.kernel_thread_id, row.id, "unknown"] do
      assert {:error, _} = History.read(%{"thread_id" => id}, ctx)
      assert {:error, _} = History.search(%{"thread_id" => id, "query" => "private"}, ctx)
    end

    forged = %{ctx | project_id: other.id}
    assert {:error, _} = History.sessions(%{}, forged)
    assert {:error, _} = History.read(%{"thread_id" => row.kernel_thread_id}, forged)
    Ash.destroy!(row)
    assert {:error, _} = History.read(%{}, context(row))
  end

  test "standalone kernels may only read themselves", %{ctx: ctx} do
    standalone = %Context{thread_id: "standalone-#{Ash.UUID.generate()}"}
    message(standalone.thread_id, 1, "standalone")
    assert {:ok, %{entries: [_]}} = History.read(%{}, standalone)
    assert {:error, _} = History.sessions(%{}, standalone)
    assert {:error, _} = History.read(%{"thread_id" => ctx.thread_id}, standalone)
  end

  test "text projection distinguishes speakers and calls while omitting hidden/image inputs", %{
    ctx: ctx
  } do
    append(ctx.thread_id, 1, :user_message, %{
      "content" => [
        %{"type" => "input_text", "text" => "可见文本"},
        %{"type" => "input_image", "image_url" => "data:image/png;base64,IMAGE_SECRET"}
      ]
    })

    append(
      ctx.thread_id,
      2,
      :user_message,
      %{"content" => "别的 agent 的建议"},
      %{"from" => "reader"}
    )

    append(ctx.thread_id, 3, :agent_message, %{
      "content" => [%{"type" => "output_text", "text" => "准备执行"}]
    })

    append(ctx.thread_id, 4, :function_call, %{
      "name" => "exec_command",
      "call_id" => "call-1",
      "arguments" => ~s({"cmd":"mix test"})
    })

    append(ctx.thread_id, 5, :function_call_output, %{
      "call_id" => "call-1",
      "output" => "tests passed"
    })

    for {kind, seq} <- Enum.with_index([:reasoning, :context, :screenshot, :activity], 6),
        do: message(ctx.thread_id, seq, "HIDDEN_SECRET", kind)

    assert {:ok, %{entries: entries}} = History.read(%{}, ctx)
    assert length(entries) == 5
    assert Enum.at(entries, 1).role == "external_message"
    assert Enum.at(entries, 1).from == "reader"
    assert Enum.at(entries, 3).tool_name == "exec_command"
    assert Enum.at(entries, 4).call_id == "call-1"
    assert Enum.at(entries, 4).text == "tests passed"
    refute Jason.encode!(entries) =~ "SECRET"
    assert {:ok, %{matches: []}} = History.search(%{"query" => "SECRET"}, ctx)
  end

  test "search advances over empty pages and preserves a snapshot ceiling", %{ctx: ctx} do
    for seq <- 1..200, do: message(ctx.thread_id, seq, "miss")
    message(ctx.thread_id, 201, "中文命中")

    assert {:ok, first} = History.search(%{"query" => "命中"}, ctx)
    assert first.matches == []
    assert first.scanned == 200
    assert first.next_after_seq == 200
    assert first.through_seq == 201
    message(ctx.thread_id, 202, "后来的命中")

    assert {:ok, last} =
             History.search(
               %{
                 "query" => "命中",
                 "after_seq" => first.next_after_seq,
                 "through_seq" => first.through_seq
               },
               ctx
             )

    assert [%{seq: 201}] = last.matches
    refute last.has_more
    assert last.next_after_seq == nil
  end

  test "many hits do not skip matches when paginating", %{ctx: ctx} do
    for seq <- 1..25, do: message(ctx.thread_id, seq, "MATCH")
    assert {:ok, first} = History.search(%{"query" => "match"}, ctx)
    assert length(first.matches) == 20
    assert first.next_after_seq == 20

    assert {:ok, next} =
             History.search(
               %{"query" => "match", "after_seq" => 20, "through_seq" => first.through_seq},
               ctx
             )

    assert Enum.map(next.matches, & &1.seq) == Enum.to_list(21..25)
    refute next.has_more
  end

  test "long Unicode entries can be read in chunks and search shows the matching tail", %{
    ctx: ctx
  } do
    text = String.duplicate("文", 3_000) <> "İ尾部"
    message(ctx.thread_id, 1, text)
    assert {:ok, %{entries: [first]}} = History.read(%{"seq" => 1}, ctx)
    assert first.next_offset == 2_000

    assert {:ok, %{entries: [last]}} =
             History.read(%{"seq" => 1, "offset" => first.next_offset}, ctx)

    assert first.text <> last.text == text
    assert last.next_offset == nil
    assert {:ok, %{matches: [hit]}} = History.search(%{"query" => "İ尾部"}, ctx)
    assert hit.text =~ "İ尾部"
    assert hit.offset == 2_800
    message(ctx.thread_id, 2, "next")
    assert {:ok, %{next_after_seq: 1}} = History.read(%{"limit" => 1}, ctx)
  end

  test "invalid arguments are errors rather than unbounded queries", %{ctx: ctx} do
    for args <- [%{"limit" => 0}, %{"limit" => 21}, %{"seq" => -1}, %{"offset" => 2}],
        do: assert({:error, _} = History.read(args, ctx))

    for query <- ["", "   ", String.duplicate("x", 1_001)],
        do: assert({:error, _} = History.search(%{"query" => query}, ctx))

    assert {:error, _} = History.sessions(%{"limit" => 51}, ctx)
  end

  test "identity and tools are injected on every request, not other phases", %{ctx: ctx} do
    for _ <- 1..2 do
      step =
        Step.new(
          thread_id: ctx.thread_id,
          project_id: ctx.project_id,
          assigns: %{parent: "parent-kernel"}
        )
        |> HistoryPlug.call([])

      assert Map.has_key?(step.tools, "history_search")
      assert Enum.join(step.instructions) =~ ctx.thread_id
      assert Enum.join(step.instructions) =~ ctx.project_id
      assert Enum.join(step.instructions) =~ "parent-kernel"
    end

    for phase <- [:response, :turn_end] do
      step = Step.new(phase: phase, thread_id: ctx.thread_id)
      assert HistoryPlug.call(step, []) == step
    end

    assert HistoryPlug.call(Step.new(), []).tools == %{}
    assert {HistoryPlug, []} in Longx.Agent.Pipelines.Default.plugs()

    tool = Enum.find(HistoryPlug.__agent_tools__(), &(&1.name == "history_read"))
    message(ctx.thread_id, 1, "tool result")
    assert {:ok, json} = Tool.call(tool, %{}, ctx)
    assert [%{"text" => "tool result"}] = Jason.decode!(json)["entries"]
  end
end
