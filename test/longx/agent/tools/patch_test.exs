defmodule Longx.Agent.Tools.PatchTest do
  use ExUnit.Case, async: true

  alias Longx.Agent.Tools.Patch

  setup do
    dir = Path.join(System.tmp_dir!(), "longx-patch-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  describe "parse/1" do
    test "add, delete and update hunks with context, moves and end-of-file" do
      text = """
      *** Begin Patch
      *** Add File: new.txt
      +hello
      +world
      *** Delete File: old.txt
      *** Update File: lib/a.ex
      *** Move to: lib/b.ex
      @@ def one do
      -  1
      +  :one
      @@
       def two do
      -  2
      +  :two
       end
      *** End of File
      *** End Patch
      """

      assert {:ok, hunks} = Patch.parse(text)

      assert [
               {:add, "new.txt", "hello\nworld\n"},
               {:delete, "old.txt"},
               {:update, "lib/a.ex", "lib/b.ex", [chunk1, chunk2]}
             ] = hunks

      assert %{context: "def one do", old: ["  1"], new: ["  :one"], eof?: false} = chunk1

      # the prefix character is stripped; context lines belong to both sides
      assert %{context: nil, old: ["def two do", "  2", "end"], eof?: true} = chunk2
      assert chunk2.new == ["def two do", "  :two", "end"]
    end

    test "markers may carry surrounding whitespace; a missing header is an error" do
      assert {:ok, [{:delete, "x"}]} =
               Patch.parse("  *** Begin Patch \n*** Delete File: x\n*** End Patch\n")

      assert {:error, message} = Patch.parse("*** Delete File: x\n")
      assert message =~ "Begin Patch"

      assert {:error, _} =
               Patch.parse("*** Begin Patch\n*** Update File: a\n~ weird\n*** End Patch\n")
    end
  end

  describe "apply/2" do
    test "adds, updates (in place and moved) and deletes files under the cwd", %{dir: dir} do
      File.write!(Path.join(dir, "a.ex"), "def one do\n  1\nend\n\ndef two do\n  2\nend\n")
      File.write!(Path.join(dir, "gone.txt"), "bye\n")

      {:ok, hunks} =
        Patch.parse("""
        *** Begin Patch
        *** Add File: sub/new.txt
        +hello
        *** Delete File: gone.txt
        *** Update File: a.ex
        @@ def one do
        -  1
        +  :one
        @@ def two do
        -  2
        +  :two
        *** End Patch
        """)

      assert {:ok, changes} = Patch.apply(hunks, dir)

      assert [
               %{"path" => new, "kind" => "add"},
               %{"path" => gone, "kind" => "delete"},
               %{"path" => a, "kind" => "update"}
             ] = changes

      assert new == Path.join(dir, "sub/new.txt")
      assert gone == Path.join(dir, "gone.txt")
      assert a == Path.join(dir, "a.ex")
      assert File.read!(new) == "hello\n"
      refute File.exists?(gone)
      assert File.read!(a) == "def one do\n  :one\nend\n\ndef two do\n  :two\nend\n"
    end

    test "a move rewrites and renames; a context that is not found is a readable error", %{
      dir: dir
    } do
      File.write!(Path.join(dir, "a.txt"), "x\ny\n")

      {:ok, hunks} =
        Patch.parse(
          "*** Begin Patch\n*** Update File: a.txt\n*** Move to: b.txt\n@@\n-y\n+z\n*** End Patch\n"
        )

      assert {:ok, [%{"kind" => "update", "path" => b, "moved_from" => a}]} =
               Patch.apply(hunks, dir)

      assert b == Path.join(dir, "b.txt")
      assert a == Path.join(dir, "a.txt")
      refute File.exists?(a)
      assert File.read!(b) == "x\nz\n"

      {:ok, hunks} =
        Patch.parse("*** Begin Patch\n*** Update File: b.txt\n@@\n-nope\n+q\n*** End Patch\n")

      assert {:error, message} = Patch.apply(hunks, dir)
      assert message =~ "b.txt"
      assert message =~ "nope"
      assert File.read!(Path.join(dir, "b.txt")) == "x\nz\n"
    end

    test "trailing whitespace differences still match; an update of a missing file fails before touching anything",
         %{dir: dir} do
      File.write!(Path.join(dir, "w.txt"), "keep  \nold\n")

      {:ok, hunks} =
        Patch.parse(
          "*** Begin Patch\n*** Update File: w.txt\n@@\n keep\n-old\n+new\n*** End Patch\n"
        )

      assert {:ok, _} = Patch.apply(hunks, dir)
      assert File.read!(Path.join(dir, "w.txt")) == "keep  \nnew\n"

      {:ok, hunks} =
        Patch.parse(
          "*** Begin Patch\n*** Add File: c.txt\n+c\n*** Update File: missing.txt\n@@\n-a\n+b\n*** End Patch\n"
        )

      assert {:error, message} = Patch.apply(hunks, dir)
      assert message =~ "missing.txt"
      refute File.exists?(Path.join(dir, "c.txt"))
    end
  end

  test "unified diffs for the UI: an add, an update and a delete" do
    assert Patch.unified_diff("a.txt", "x\ny\n", "x\nz\n") ==
             "--- a/a.txt\n+++ b/a.txt\n@@ -1,2 +1,2 @@\n x\n-y\n+z\n"

    assert Patch.unified_diff("n.txt", nil, "one\n") ==
             "--- /dev/null\n+++ b/n.txt\n@@ -0,0 +1 @@\n+one\n"

    assert Patch.unified_diff("d.txt", "bye\n", nil) ==
             "--- a/d.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-bye\n"
  end
end
