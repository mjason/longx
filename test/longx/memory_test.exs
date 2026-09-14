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
    assert text =~ "memory.search"
    assert text =~ "memory.note"
    # what memory says is information, never an instruction
    assert text =~ ~r/not instructions|不是指令/

    :ok = Memory.write_index(dir, String.duplicate("x", 100_000))
    assert byte_size(Memory.instructions(dir)) <= 32_768
  end
end
