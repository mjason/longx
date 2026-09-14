defmodule Longx.Memory.PipelineTest do
  @moduledoc """
  The global memory's pipeline: idle threads are read from codex's rollouts
  and distilled into notes (Extract); notes are folded into MEMORY.md
  (Consolidate); the Worker runs both. The model is a function here.
  """
  use Longx.DataCase, async: false

  alias Longx.Memory
  alias Longx.Memory.{Consolidate, Extract, Worker}
  alias Longx.Projects

  setup do
    dir = Path.join(System.tmp_dir!(), "longx-mempipe-#{System.unique_integer([:positive])}")
    homes = Path.join(System.tmp_dir!(), "longx-memhomes-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:longx, Longx.Memory, [])
    previous_home = Application.get_env(:longx, Longx.Codex.Home, [])
    Application.put_env(:longx, Longx.Memory, Keyword.put(previous, :dir, dir))
    Application.put_env(:longx, Longx.Codex.Home, Keyword.put(previous_home, :dir, homes))

    on_exit(fn ->
      Application.put_env(:longx, Longx.Memory, previous)
      Application.put_env(:longx, Longx.Codex.Home, previous_home)
      File.rm_rf!(dir)
      File.rm_rf!(homes)
    end)

    root = Path.join(System.tmp_dir!(), "longx-memproj-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    project = Projects.create_project!(%{name: "流水线项目", root_path: root})
    %{dir: dir, homes: homes, project: project}
  end

  defp thread!(project, codex_id, attrs \\ %{}) do
    {activity, attrs} =
      Map.pop(attrs, :last_activity_at, DateTime.add(DateTime.utc_now(), -3, :hour))

    thread =
      Projects.create_thread!(
        Map.merge(
          %{
            project_id: project.id,
            codex_thread_id: codex_id,
            cwd: project.root_path,
            sandbox: :workspace_write,
            approval_policy: :on_request,
            status: :idle
          },
          attrs
        )
      )

    Projects.touch_thread!(thread, %{last_activity_at: activity})
  end

  defp rollout!(homes, project, codex_id, entries) do
    day = Path.join([homes, project.id, "sessions/2026/09/14"])
    File.mkdir_p!(day)

    lines =
      Enum.map(entries, fn
        {:user, t} ->
          %{
            type: "response_item",
            payload: %{type: "message", role: "user", content: [%{type: "input_text", text: t}]}
          }

        {:assistant, t} ->
          %{
            type: "response_item",
            payload: %{
              type: "message",
              role: "assistant",
              content: [%{type: "output_text", text: t}]
            }
          }
      end)

    File.write!(
      Path.join(day, "rollout-2026-09-14T12-00-00-#{codex_id}.jsonl"),
      Enum.map_join(lines, "", &(Jason.encode!(&1) <> "\n"))
    )
  end

  describe "Extract" do
    test "candidates: idle long enough, not yet extracted since their last activity, root threads of projects with the memory on",
         %{project: project} do
      old = thread!(project, "thr_old")
      _fresh = thread!(project, "thr_fresh", %{last_activity_at: DateTime.utc_now()})
      _child = thread!(project, "thr_child", %{parent_thread_id: old.id, agent_path: "/root/a"})
      done = thread!(project, "thr_done")
      {:ok, _} = Projects.mark_thread_extracted(done)

      assert Enum.map(Extract.candidates(idle_hours: 1), & &1.codex_thread_id) == ["thr_old"]

      other = Path.join(System.tmp_dir!(), "longx-memquiet-#{System.unique_integer([:positive])}")
      File.mkdir_p!(other)
      on_exit(fn -> File.rm_rf!(other) end)
      quiet = Projects.create_project!(%{name: "安静", root_path: other, global_memory: false})
      _ = thread!(quiet, "thr_quiet")
      assert Enum.map(Extract.candidates(idle_hours: 1), & &1.codex_thread_id) == ["thr_old"]
    end

    test "a thread's rollout goes to the model; its facts become notes with provenance; the thread is marked",
         %{project: project, homes: homes, dir: dir} do
      thread = thread!(project, "thr_1")
      rollout!(homes, project, "thr_1", [{:user, "以后 commit message 都用中文"}, {:assistant, "好的"}])
      test_pid = self()

      complete = fn instructions, input, _opts ->
        send(test_pid, {:model, instructions, input})
        {:ok, ~s(```json\n["Commit message 用中文。", "用户偏好 Tabs 缩进。"]\n```)}
      end

      assert {:ok, 2} = Extract.run(thread, complete: complete)
      assert_receive {:model, instructions, input}
      assert instructions =~ "跨项目"
      assert input =~ "用户：以后 commit message 都用中文"

      assert [
               %{text: "用户偏好 Tabs 缩进。"},
               %{text: "Commit message 用中文。", project: "流水线项目", thread: "thr_1", source: "auto"}
             ] =
               Memory.notes(dir)

      assert %DateTime{} = Ash.get!(Projects.Thread, thread.id).memory_extracted_at
      assert Extract.candidates(idle_hours: 1) == []
    end

    test "nothing worth keeping (or no rollout) still marks the thread, so it is not read again",
         %{project: project, homes: homes, dir: dir} do
      thread = thread!(project, "thr_2")
      rollout!(homes, project, "thr_2", [{:user, "hi"}, {:assistant, "hello"}])
      assert {:ok, 0} = Extract.run(thread, complete: fn _, _, _ -> {:ok, "[]"} end)
      assert Memory.notes(dir) == []
      assert %DateTime{} = Ash.get!(Projects.Thread, thread.id).memory_extracted_at

      gone = thread!(project, "thr_3")

      assert {:ok, 0} =
               Extract.run(gone, complete: fn _, _, _ -> flunk("no rollout, no model call") end)

      assert %DateTime{} = Ash.get!(Projects.Thread, gone.id).memory_extracted_at
    end

    test "a model failure leaves the thread for next time", %{project: project, homes: homes} do
      thread = thread!(project, "thr_4")
      rollout!(homes, project, "thr_4", [{:user, "x"}])

      assert {:error, _} =
               Extract.run(thread, complete: fn _, _, _ -> {:error, {:status, 500, "down"}} end)

      assert Ash.get!(Projects.Thread, thread.id).memory_extracted_at == nil
    end
  end

  describe "Consolidate" do
    test "folds the notes not yet folded into MEMORY.md through the model, and remembers which",
         %{dir: dir} do
      :ok = Memory.write_index(dir, "# MEMORY\n\n- Tabs over spaces\n")
      {:ok, n1} = Memory.add_note(dir, "Commit message 用中文。", project: "p")
      test_pid = self()

      complete = fn _instructions, input, _ ->
        send(test_pid, {:model, input})
        {:ok, "# MEMORY\n\n## 代码风格\n- Tabs over spaces\n- Commit message 用中文\n"}
      end

      assert {:ok, 1} = Consolidate.run(dir, complete: complete)
      assert_receive {:model, input}
      assert input =~ "Tabs over spaces" and input =~ "Commit message 用中文"
      assert Memory.index(dir) =~ "## 代码风格"
      assert Memory.pending_notes(dir) == []
      # the folded note is not handed to the model again — it is in MEMORY.md now
      refute Memory.instructions(dir) =~ "最近的笔记"
      assert Memory.instructions(dir) =~ "Commit message 用中文"

      # nothing new: no model call
      assert {:ok, 0} = Consolidate.run(dir, complete: fn _, _, _ -> flunk("nothing to fold") end)
      {:ok, _n2} = Memory.add_note(dir, "second", project: "p")
      assert [%{file: _}] = Memory.pending_notes(dir)
      assert n1 in Enum.map(Memory.notes(dir), & &1.file)
    end

    test "an answer that lost most of the index is refused", %{dir: dir} do
      :ok =
        Memory.write_index(
          dir,
          "# MEMORY\n\n" <> String.duplicate("- a durable fact about the user\n", 30)
        )

      {:ok, _} = Memory.add_note(dir, "one more", project: "p")

      assert {:error, :suspicious_answer} =
               Consolidate.run(dir, complete: fn _, _, _ -> {:ok, "# MEMORY\n"} end)

      assert Memory.index(dir) =~ "durable fact"
      assert [_] = Memory.pending_notes(dir)
    end
  end

  describe "Worker" do
    test "one run extracts the candidates then consolidates; the report and the switch live in the state file",
         %{project: project, homes: homes, dir: dir} do
      thread = thread!(project, "thr_w")
      rollout!(homes, project, "thr_w", [{:user, "记住我用 pnpm"}, {:assistant, "好"}])

      complete = fn instructions, _input, _ ->
        if instructions =~ "MEMORY.md 的新版本",
          do: {:ok, "# MEMORY\n\n- 用 pnpm\n"},
          else: {:ok, ~s(["用户用 pnpm。"])}
      end

      assert {:ok, %{extracted: 1, notes: 1, consolidated: 1}} =
               Worker.run_now(complete: complete)

      assert Memory.index(dir) =~ "pnpm"
      assert %{auto_extract: true, last_run_at: %DateTime{}, last_error: nil} = Memory.status(dir)
      assert %DateTime{} = Ash.get!(Projects.Thread, thread.id).memory_extracted_at

      :ok = Memory.set_auto_extract(dir, false)
      assert %{auto_extract: false} = Memory.status(dir)
      _ = thread!(project, "thr_w2")
      rollout!(homes, project, "thr_w2", [{:user, "x"}])
      # switched off: nothing is read, notes already there still get folded
      assert {:ok, %{extracted: 0}} = Worker.run_now(complete: fn _, _, _ -> flunk("off") end)
    end
  end
end
