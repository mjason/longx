defmodule Longx.SystemTest do
  # Node-level facts for the UI: the directory picker's listing.
  use ExUnit.Case, async: true

  alias Longx.System, as: LongxSystem

  setup do
    root = Path.join(System.tmp_dir!(), "longx-fs-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "beta"))
    File.mkdir_p!(Path.join(root, "alpha/.git"))
    File.mkdir_p!(Path.join(root, ".hidden"))
    File.write!(Path.join(root, "file.txt"), "x")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "lists subdirectories only, sorted, flagging git repositories", %{root: root} do
    assert {:ok, listing} = LongxSystem.list_directory(%{path: root})
    assert listing.path == root
    assert listing.parent == Path.dirname(root)
    assert Enum.map(listing.entries, & &1.name) == ["alpha", "beta"]
    assert Enum.find(listing.entries, &(&1.name == "alpha")).git
    refute Enum.find(listing.entries, &(&1.name == "beta")).git
    assert Enum.all?(listing.entries, &String.starts_with?(&1.path, root))
    refute listing.git
  end

  test "hidden directories only when asked", %{root: root} do
    assert {:ok, listing} = LongxSystem.list_directory(%{path: root, show_hidden: true})
    assert ".hidden" in Enum.map(listing.entries, & &1.name)
  end

  test "a repository itself is flagged", %{root: root} do
    assert {:ok, %{git: true, entries: []}} =
             LongxSystem.list_directory(%{path: Path.join(root, "alpha")})
  end

  test "no path means the home directory; roots are offered for jumping", %{} do
    assert {:ok, listing} = LongxSystem.list_directory(%{})
    assert listing.path == System.user_home!()
    assert Enum.any?(listing.roots, &(&1.path == System.user_home!()))
    assert Enum.any?(listing.roots, &(&1.path == "/"))
  end

  test "missing or non-directory paths are errors", %{root: root} do
    assert {:error, %Ash.Error.Invalid{}} =
             LongxSystem.list_directory(%{path: Path.join(root, "nope")})

    assert {:error, %Ash.Error.Invalid{}} =
             LongxSystem.list_directory(%{path: Path.join(root, "file.txt")})
  end

  test "create_directory makes one directory under an existing parent and answers its listing entry",
       %{root: root} do
    assert {:ok, %{name: "new-app", path: path, git: false}} =
             LongxSystem.create_directory(%{parent: root, name: "new-app"})

    assert path == Path.join(root, "new-app")
    assert File.dir?(path)

    # a name is one path segment, never a path; an existing name is refused
    assert {:error, %Ash.Error.Invalid{}} =
             LongxSystem.create_directory(%{parent: root, name: "a/b"})

    assert {:error, %Ash.Error.Invalid{}} =
             LongxSystem.create_directory(%{parent: root, name: ".."})

    assert {:error, %Ash.Error.Invalid{}} =
             LongxSystem.create_directory(%{parent: root, name: "new-app"})

    assert {:error, %Ash.Error.Invalid{}} =
             LongxSystem.create_directory(%{parent: Path.join(root, "nope"), name: "x"})
  end

  test "relative paths are refused", _ do
    assert {:error, %Ash.Error.Invalid{}} = LongxSystem.list_directory(%{path: "relative/dir"})
  end
end
