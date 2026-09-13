defmodule Longx.Projects.WorkspaceTest do
  @moduledoc "The project's files as the file tree and the editor see them: inside the root, always."
  use ExUnit.Case, async: true

  alias Longx.Projects.Workspace

  setup do
    root = Path.join(System.tmp_dir!(), "longx-ws-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib/app"))
    File.mkdir_p!(Path.join(root, ".git"))
    File.write!(Path.join(root, "README.md"), "# hi\n")
    File.write!(Path.join(root, "lib/app/main.ex"), "defmodule Main do\nend\n")
    File.write!(Path.join(root, ".gitignore"), "_build\n")
    File.write!(Path.join(root, "pic.png"), <<137, 80, 78, 71, 0, 1, 2>>)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "list/2: one level, directories first, dotfiles shown, .git never", %{root: root} do
    assert {:ok, entries} = Workspace.list(root, "")

    assert Enum.map(entries, &{&1.path, &1.kind}) == [
             {"lib", :dir},
             {".gitignore", :file},
             {"pic.png", :file},
             {"README.md", :file}
           ]

    assert %{name: "README.md", size: 5} = Enum.find(entries, &(&1.path == "README.md"))

    assert {:ok, [%{path: "lib/app", kind: :dir}]} = Workspace.list(root, "lib")

    assert {:ok, [%{path: "lib/app/main.ex", kind: :file, name: "main.ex"}]} =
             Workspace.list(root, "lib/app")

    assert {:error, :not_found} = Workspace.list(root, "nope")
  end

  test "paths never leave the root", %{root: root} do
    for bad <- ["../etc", "/etc/passwd", "lib/../../x", "lib/../.."] do
      assert {:error, :outside_root} = Workspace.list(root, bad), bad
      assert {:error, :outside_root} = Workspace.read(root, bad), bad
    end
  end

  test "read/2 gives text with its size; binaries and big files are flagged, not loaded", %{
    root: root
  } do
    assert {:ok, %{content: "# hi\n", size: 5, binary: false, truncated: false}} =
             Workspace.read(root, "README.md")

    assert {:ok, %{binary: true, content: nil, size: 7}} = Workspace.read(root, "pic.png")

    big = Path.join(root, "big.txt")
    File.write!(big, String.duplicate("x", 2_000_001))

    assert {:ok, %{truncated: true, size: 2_000_001, content: content}} =
             Workspace.read(root, "big.txt")

    assert byte_size(content) == 1_000_000

    assert {:error, :not_found} = Workspace.read(root, "missing.txt")
    assert {:error, :not_a_file} = Workspace.read(root, "lib")
  end

  test "write/3, create/3, rename/3 and delete/2 — files and directories", %{root: root} do
    assert :ok = Workspace.write(root, "lib/app/main.ex", "defmodule Main do\n  # edited\nend\n")
    assert File.read!(Path.join(root, "lib/app/main.ex")) =~ "edited"
    # writing creates a missing file; never a missing directory
    assert :ok = Workspace.write(root, "lib/app/new.ex", "")
    assert {:error, :not_found} = Workspace.write(root, "nope/x.ex", "")

    assert {:ok, %{path: "lib/app/util.ex", kind: :file}} =
             Workspace.create(root, "lib/app/util.ex", :file)

    assert {:ok, %{path: "lib/other", kind: :dir}} = Workspace.create(root, "lib/other", :dir)
    assert {:error, :exists} = Workspace.create(root, "lib/other", :dir)

    assert {:ok, %{path: "lib/app/util2.ex"}} =
             Workspace.rename(root, "lib/app/util.ex", "lib/app/util2.ex")

    assert {:error, :exists} = Workspace.rename(root, "lib/app/util2.ex", "README.md")
    assert {:error, :outside_root} = Workspace.rename(root, "README.md", "../README.md")

    assert :ok = Workspace.delete(root, "lib/app/util2.ex")
    assert :ok = Workspace.delete(root, "lib/other")
    refute File.exists?(Path.join(root, "lib/other"))
    assert {:error, :not_found} = Workspace.delete(root, "lib/other")
    # the root itself and .git are off limits
    assert {:error, :outside_root} = Workspace.delete(root, "")
    assert {:error, :outside_root} = Workspace.delete(root, ".git")
  end
end
