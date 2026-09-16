defmodule Longx.Tools.MemoryToolsTest do
  @moduledoc "`memory.note` / `memory.search` / `memory.read`: the agent's hands on the global memory."
  use Longx.DataCase, async: false

  alias Longx.Codex.Tool.Context
  alias Longx.Codex.Tool.Registry
  alias Longx.Tools.Memory.{Note, Read, Search}

  setup do
    dir = Path.join(System.tmp_dir!(), "longx-memtool-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:longx, Longx.Memory, [])
    Application.put_env(:longx, Longx.Memory, Keyword.put(previous, :dir, dir))

    on_exit(fn ->
      Application.put_env(:longx, Longx.Memory, previous)
      Longx.Test.TmpDirs.rm_rf!(dir)
    end)

    %{dir: dir, ctx: %Context{cwd: "/tmp", thread_id: "thr_x"}}
  end

  test "registered under the memory namespace, on by default (unlike other new tools)" do
    for {mod, name} <- [{Note, "note"}, {Search, "search"}, {Read, "read"}] do
      assert mod.namespace() == "memory"
      assert mod.name() == name
      assert {:ok, %{module: ^mod}} = Registry.fetch("memory", name)
    end

    {:ok, tools} = Longx.AI.list_tools()
    memory = Enum.filter(tools, &(&1.namespace == "memory"))
    assert length(memory) == 3
    assert Enum.all?(memory, & &1.enabled)
    # a switch someone turned off stays off across a re-sync
    {:ok, row} = Longx.AI.get_tool("memory", "note")
    Longx.AI.set_tool_enabled!(row, %{enabled: false})
    {:ok, tools} = Longx.AI.list_tools()
    refute Enum.find(tools, &(&1.qualified_name == "memory.note")).enabled
  end

  test "note writes a note with the thread's project as provenance; search and read find it", %{
    ctx: ctx,
    dir: dir
  } do
    tmp = Path.join(System.tmp_dir!(), "longx-memproj-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    project = Longx.Projects.create_project!(%{name: "记忆项目", root_path: tmp})

    Longx.Projects.create_thread!(%{
      project_id: project.id,
      codex_thread_id: "thr_x",
      cwd: tmp,
      sandbox: :workspace_write,
      approval_policy: :on_request
    })

    assert {:ok, "notes/" <> _ = file} = Note.call(%{"note" => "The user prefers tabs."}, ctx)
    assert [%{project: "记忆项目", thread: "thr_x"}] = Longx.Memory.notes(dir)

    assert {:ok, json} = Search.call(%{"query" => "tabs"}, ctx)
    assert %{"hits" => [%{"file" => ^file, "text" => text}]} = Jason.decode!(json)
    assert text =~ "prefers tabs"
    assert {:ok, json} = Search.call(%{"query" => "spaces"}, ctx)
    assert %{"hits" => []} = Jason.decode!(json)

    assert {:ok, content} = Read.call(%{"file" => file}, ctx)
    assert content =~ "prefers tabs"
    assert {:ok, index} = Read.call(%{}, ctx)
    assert index =~ "# MEMORY"
    assert {:error, message} = Read.call(%{"file" => "../secret"}, ctx)
    assert message =~ "MEMORY.md" or message =~ "notes/"
    assert {:error, _} = Note.call(%{"note" => "  "}, ctx)
  end

  test "a thread nobody knows (an ad-hoc codex) still gets to note, without provenance", %{
    ctx: ctx,
    dir: dir
  } do
    assert {:ok, _} = Note.call(%{"note" => "plain"}, %{ctx | thread_id: "thr_unknown"})
    assert [%{project: nil, thread: "thr_unknown"}] = Longx.Memory.notes(dir)
  end
end
