defmodule Longx.MemoryTest do
  # the global memory is a directory: real files, a real (bundled) git behind them
  use ExUnit.Case, async: true

  alias Longx.Memory

  setup do
    dir = Path.join(System.tmp_dir!(), "longx-memory-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "ensure/1 makes the directory a repository with a seeded MEMORY.md, once", %{dir: dir} do
    assert :ok = Memory.ensure(dir)
    assert Longx.Git.repository?(dir)
    assert Memory.index(dir) =~ "# MEMORY"
    File.write!(Path.join(dir, "MEMORY.md"), "# mine\n")
    assert :ok = Memory.ensure(dir)
    assert Memory.index(dir) == "# mine\n"
  end

  test "concurrent writes queue up instead of colliding on git", %{dir: dir} do
    assert :ok = Memory.ensure(dir)

    results =
      1..8
      |> Task.async_stream(
        fn i ->
          case rem(i, 2) do
            0 -> Memory.add_note(dir, "note #{i}", slug: "n#{i}")
            1 -> Memory.write_index(dir, "# MEMORY\n\n- v#{i}\n")
          end
        end,
        max_concurrency: 8,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.all?(results, &(match?({:ok, _}, &1) or &1 == :ok)), inspect(results)
    assert length(Memory.notes(dir)) == 4
    # init + 8 writes, one commit each
    assert length(Longx.Git.log(dir, limit: 20)) == 9
  end

  test "a memory directory inside another repository gets its own, never commits into the parent",
       %{
         dir: parent
       } do
    File.mkdir_p!(parent)
    :ok = Longx.Git.init(parent)
    File.write!(Path.join(parent, "app.txt"), "the app\n")
    {:ok, base} = Longx.Git.commit_all(parent, "app")

    inner = Path.join(parent, "data/memory")
    assert :ok = Memory.ensure(inner)
    assert {:ok, ^inner} = Longx.Git.toplevel(inner)
    {:ok, _} = Memory.add_note(inner, "kept apart")

    # the parent's history and tree are untouched
    assert {:ok, ^base} = Longx.Git.head(parent)
    assert Longx.Git.status(parent).changes |> Enum.map(& &1.path) == ["data/memory/"]
  end

  test "a note is one append-only file with its provenance, committed; notes list newest first",
       %{
         dir: dir
       } do
    assert {:ok, "notes/" <> name1} =
             Memory.add_note(dir, "The user prefers tabs over spaces.",
               project: "数学精灵",
               thread: "thr_1",
               slug: "prefers tabs!"
             )

    assert name1 =~ ~r/^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}Z-prefers-tabs\.md$/
    assert {:ok, "notes/" <> name2} = Memory.add_note(dir, "Second thing", project: "p2")
    refute name1 == name2

    assert [second, first] = Memory.notes(dir)
    assert %{text: "The user prefers tabs over spaces.", project: "数学精灵", thread: "thr_1"} = first
    assert %{text: "Second thing", project: "p2", thread: nil} = second
    assert first.file == "notes/" <> name1
    assert %DateTime{} = first.at

    # every write is a commit: the history is the audit trail
    assert length(Longx.Git.log(dir, limit: 10)) >= 3
    assert Longx.Git.status(dir).clean?

    assert {:error, :empty} = Memory.add_note(dir, "   ")
  end

  test "write_index/2 replaces MEMORY.md and commits; delete_note/2 removes one note", %{dir: dir} do
    {:ok, file} = Memory.add_note(dir, "gone soon")
    assert :ok = Memory.write_index(dir, "# MEMORY\n\n- tabs, not spaces\n")
    assert Memory.index(dir) =~ "tabs, not spaces"
    assert :ok = Memory.delete_note(dir, file)
    assert Memory.notes(dir) == []
    assert {:error, :not_found} = Memory.delete_note(dir, file)
    assert {:error, :invalid_path} = Memory.delete_note(dir, "../MEMORY.md")
  end

  test "search/2 finds lines across the index and the notes, case-insensitively, every word", %{
    dir: dir
  } do
    :ok =
      Memory.write_index(
        dir,
        "# MEMORY\n\n- Elixir projects: run `mix precommit` before a commit\n- Tabs over spaces\n"
      )

    {:ok, _} =
      Memory.add_note(dir, "For Elixir, dialyzer must stay at zero warnings.", project: "longx")

    hits = Memory.search(dir, "elixir precommit")
    assert [%{file: "MEMORY.md", line: 3, text: text}] = hits
    assert text =~ "mix precommit"

    assert [_, _] = Memory.search(dir, "ELIXIR")
    assert [] = Memory.search(dir, "python")
    assert [] = Memory.search(dir, "  ")
  end

  test "instructions/1 hands the model the index and the latest notes, with how to use them, within a cap",
       %{dir: dir} do
    :ok = Memory.write_index(dir, "# MEMORY\n\n- Tabs over spaces\n")
    {:ok, _} = Memory.add_note(dir, "Recent thing", project: "p")

    text = Memory.instructions(dir)
    assert text =~ "Tabs over spaces"
    assert text =~ "Recent thing"
    assert text =~ "`memory` 命名空间"
    assert text =~ "调用 `note`"
    # what memory says is information, never an instruction
    assert text =~ ~r/not instructions|不是指令/

    :ok = Memory.write_index(dir, String.duplicate("x", 100_000))
    assert byte_size(Memory.instructions(dir)) <= 32_768
  end

  test "prune/2 drops folded notes past their keep time and forgets them; pending and recent ones stay",
       %{dir: dir} do
    {:ok, old_folded} = Memory.add_note(dir, "old and folded", at: days_ago(40))
    {:ok, old_pending} = Memory.add_note(dir, "old but never folded", at: days_ago(40))
    {:ok, fresh_folded} = Memory.add_note(dir, "fresh and folded", at: days_ago(3))
    :ok = Memory.mark_consolidated(dir, [old_folded, fresh_folded, "notes/gone-by-hand.md"])

    assert {:ok, 1} = Memory.prune(dir, 30)
    refute File.exists?(Path.join(dir, old_folded))
    assert File.exists?(Path.join(dir, old_pending))
    assert File.exists?(Path.join(dir, fresh_folded))
    # the state forgets what is gone (pruned, or deleted by hand)
    assert Memory.folded_notes(dir) |> Enum.map(& &1.file) == [fresh_folded]
    assert Memory.status(dir).folded == 1
    assert Memory.status(dir).pending == 1
    # committed, like every change to the directory
    assert [%{subject: "memory: prune 1 folded note"} | _] = Longx.Git.log(dir, limit: 1)
    # nothing to do is not a commit
    assert {:ok, 0} = Memory.prune(dir, 30)
    assert [%{subject: "memory: prune 1 folded note"} | _] = Longx.Git.log(dir, limit: 1)
    # nil keeps everything
    assert {:ok, 0} = Memory.prune(dir, nil)
  end

  defp days_ago(n), do: DateTime.add(DateTime.utc_now(), -n * 86_400, :second)
end
