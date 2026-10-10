defmodule Longx.Projects.WorkspaceTest do
  @moduledoc "The project tree and the unrestricted editor: OS permissions determine file access."
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

  test "tree paths stay relative to the root", %{root: root} do
    for bad <- ["../etc", "/etc/passwd", "lib/../../x", "lib/../.."] do
      assert {:error, :outside_root} = Workspace.list(root, bad), bad
    end
  end

  test "the editor reads and saves absolute, parent-relative, .git and symlink files", %{
    root: root
  } do
    outside = root <> "-sibling"
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf!(outside) end)
    external = Path.join(outside, "外部 文件.rb")
    File.write!(external, "original\n")
    relative = "../#{Path.basename(outside)}/#{Path.basename(external)}"
    File.ln_s!(external, Path.join(root, "linked.rb"))
    File.write!(Path.join(root, ".git/config"), "[core]\n")

    for path <- [external, relative, "linked.rb"] do
      assert {:ok, %{content: "original\n", binary: false, truncated: false}} =
               Workspace.read(root, path)

      assert :ok = Workspace.write(root, path, "saved\n")
      assert File.read!(external) == "saved\n"
      File.write!(external, "original\n")
    end

    assert {:ok, %{content: "[core]\n"}} = Workspace.read(root, ".git/config")
    assert :ok = Workspace.write(root, ".git/config", "[core]\n# saved\n")
    assert {:error, :not_a_file} = Workspace.read(root, outside)
    assert {:error, :not_found} = Workspace.read(root, Path.join(outside, "missing"))
    # OS access errors are returned, not converted to a project-boundary error or raised.
    File.chmod!(external, 0o000)

    case File.read(external) do
      {:error, reason} -> assert {:error, ^reason} = Workspace.read(root, external)
      {:ok, _} -> assert {:ok, _} = Workspace.read(root, external)
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

    # a Chinese document longer than the sniff: the sniff cuts a character in two,
    # which is not what binary means; the same at the 1 MB cut of a big one
    File.write!(Path.join(root, "研报.md"), "# 报告\n" <> String.duplicate("小市值策略研究笔记。", 2_000))

    assert {:ok, %{binary: false, truncated: false, content: "# 报告\n" <> _}} =
             Workspace.read(root, "研报.md")

    File.write!(Path.join(root, "大研报.md"), String.duplicate("小市值策略研究笔记。", 40_000))

    assert {:ok, %{binary: false, truncated: true, content: content}} =
             Workspace.read(root, "大研报.md")

    assert String.valid?(content)
    assert byte_size(content) <= 1_000_000 and byte_size(content) > 999_990
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

  test "upload/3 copies binary files into an existing directory without replacing entries", %{
    root: root
  } do
    source = Path.join(root, "upload.tmp")
    bytes = <<0, 1, 2, 255, 128>>
    File.write!(source, bytes)

    assert {:ok, %{path: "lib/app/photo.png", kind: :file, size: 5}} =
             Workspace.upload(root, "lib/app/photo.png", source)

    assert File.read!(Path.join(root, "lib/app/photo.png")) == bytes
    assert {:error, :exists} = Workspace.upload(root, "lib/app/photo.png", source)
    assert {:error, :not_found} = Workspace.upload(root, "missing/photo.png", source)
    assert {:error, :outside_root} = Workspace.upload(root, "../photo.png", source)
    assert {:error, :outside_root} = Workspace.upload(root, ".git/config", source)
  end
end
