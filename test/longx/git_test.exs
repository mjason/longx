defmodule Longx.GitTest do
  # real git processes on temp repos; independent, so async is fine
  use ExUnit.Case, async: true

  alias Longx.Git

  setup do
    dir = Path.join(System.tmp_dir!(), "longx-git-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp write!(dir, name, content), do: File.write!(Path.join(dir, name), content)

  test "the bundled git is what runs" do
    assert {:ok, exe} = Longx.Git.Runtime.executable()
    assert Git.executable() == exe
    assert Git.version() =~ ~r/^2\.53\.0/
    assert Git.lfs_version() =~ ~r/^git-lfs\/3\./
  end

  describe "run/2" do
    test "returns stdout and stderr separately with the exit status", %{dir: dir} do
      assert {:ok, %{status: 0, stdout: out, stderr: ""}} = Git.run(["init", "-q"], cd: dir)
      assert out == ""

      assert {:error, %Git.Error{status: status, stderr: err, args: ["rev-parse", "nope"]}} =
               Git.run(["rev-parse", "nope"], cd: dir)

      assert status != 0
      assert err =~ "nope"
    end

    test "speaks the C locale so messages are parseable", %{dir: dir} do
      assert {:error, %Git.Error{stderr: err}} = Git.run(["status"], cd: dir)
      assert err =~ "not a git repository"
    end
  end

  describe "repository detection and init" do
    test "a plain directory is not a repository", %{dir: dir} do
      refute Git.repository?(dir)
      assert {:error, :not_a_repository} = Git.toplevel(dir)
    end

    test "init/1 creates one; a subdirectory is inside it but not its toplevel", %{dir: dir} do
      assert :ok = Git.init(dir)
      assert Git.repository?(dir)
      assert {:ok, top} = Git.toplevel(dir)
      assert Path.expand(top) == Path.expand(dir)

      sub = Path.join(dir, "sub")
      File.mkdir_p!(sub)
      assert {:ok, top2} = Git.toplevel(sub)
      assert Path.expand(top2) == Path.expand(dir)
    end

    test "head/1 on an unborn branch", %{dir: dir} do
      :ok = Git.init(dir)
      assert {:error, :unborn} = Git.head(dir)
    end
  end

  describe "status / commit / log" do
    setup %{dir: dir} do
      :ok = Git.init(dir)
      :ok
    end

    test "status reports untracked, modified and deleted; clean after commit", %{dir: dir} do
      write!(dir, "a.txt", "a")
      assert %{clean?: false, changes: [%{path: "a.txt", status: :untracked}]} = Git.status(dir)

      assert {:ok, sha} = Git.commit_all(dir, "first")
      assert sha =~ ~r/^[0-9a-f]{40}$/
      assert %{clean?: true, changes: []} = Git.status(dir)
      assert {:ok, ^sha} = Git.head(dir)

      write!(dir, "a.txt", "aa")
      write!(dir, "b.txt", "b")
      File.rm!(Path.join(dir, "b.txt"))
      changes = Git.status(dir).changes
      assert %{path: "a.txt", status: :modified} in changes
    end

    test "commit_all works without a configured identity (Longx falls back to its own)", %{
      dir: dir
    } do
      write!(dir, "a.txt", "a")

      assert {:ok, sha} =
               Git.commit_all(dir, "no identity",
                 env: [
                   {"HOME", dir},
                   {"GIT_CONFIG_GLOBAL", "/dev/null"},
                   {"GIT_CONFIG_NOSYSTEM", "1"}
                 ]
               )

      [entry] = Git.log(dir, limit: 1)
      assert entry.sha == sha
      assert entry.subject == "no identity"
      assert entry.author == "Longx"
    end

    test "commit_all with nothing to commit is a no-op that returns the current head", %{dir: dir} do
      write!(dir, "a.txt", "a")
      {:ok, sha} = Git.commit_all(dir, "first")
      assert {:ok, ^sha} = Git.commit_all(dir, "nothing")
    end

    test "log/2 lists newest first with sha, subject, author and time", %{dir: dir} do
      write!(dir, "a.txt", "1")
      {:ok, s1} = Git.commit_all(dir, "one")
      write!(dir, "a.txt", "2")
      {:ok, s2} = Git.commit_all(dir, "two")

      assert [%{sha: ^s2, subject: "two"}, %{sha: ^s1, subject: "one"}] = Git.log(dir, limit: 10)
      assert [%{sha: ^s2, at: %DateTime{}}] = Git.log(dir, limit: 1)
    end

    test "diff/3 between two commits and against the working tree", %{dir: dir} do
      write!(dir, "a.txt", "one\n")
      {:ok, s1} = Git.commit_all(dir, "one")
      write!(dir, "a.txt", "two\n")
      {:ok, s2} = Git.commit_all(dir, "two")

      diff = Git.diff(dir, s1, s2)
      assert diff =~ "-one"
      assert diff =~ "+two"

      write!(dir, "a.txt", "three\n")
      assert Git.diff(dir, s2) =~ "+three"
      assert Git.diff(dir, s2, s2) == ""
    end
  end

  describe "restoring" do
    setup %{dir: dir} do
      :ok = Git.init(dir)
      write!(dir, "keep.txt", "v1")
      {:ok, base} = Git.commit_all(dir, "base")
      write!(dir, "keep.txt", "v2")
      write!(dir, "added.txt", "later")
      {:ok, later} = Git.commit_all(dir, "later")
      write!(dir, "untracked.txt", "junk")
      write!(dir, "keep.txt", "dirty")
      %{base: base, later: later}
    end

    test "restore_tree/2 puts files back as they were at a commit without moving the branch", %{
      dir: dir,
      base: base,
      later: later
    } do
      assert :ok = Git.restore_tree(dir, base)
      assert File.read!(Path.join(dir, "keep.txt")) == "v1"
      refute File.exists?(Path.join(dir, "added.txt"))
      refute File.exists?(Path.join(dir, "untracked.txt"))
      # history untouched: HEAD is still the later commit
      assert {:ok, ^later} = Git.head(dir)
    end

    test "reset_hard/2 moves the branch and the files", %{dir: dir, base: base} do
      assert :ok = Git.reset_hard(dir, base)
      assert {:ok, ^base} = Git.head(dir)
      assert File.read!(Path.join(dir, "keep.txt")) == "v1"
      refute File.exists?(Path.join(dir, "added.txt"))
      refute File.exists?(Path.join(dir, "untracked.txt"))
    end
  end

  describe "worktrees" do
    test "add / list / remove", %{dir: dir} do
      :ok = Git.init(dir)
      write!(dir, "a.txt", "a")
      {:ok, sha} = Git.commit_all(dir, "first")

      wt = Path.join([dir, "..", "wt-#{System.unique_integer([:positive])}"]) |> Path.expand()
      on_exit(fn -> File.rm_rf!(wt) end)

      assert :ok = Git.worktree_add(dir, wt, sha)
      assert File.read!(Path.join(wt, "a.txt")) == "a"
      assert {:ok, ^sha} = Git.head(wt)
      assert Enum.any?(Git.worktree_list(dir), &(Path.expand(&1.path) == wt and &1.head == sha))

      assert :ok = Git.worktree_remove(dir, wt)
      refute File.exists?(wt)
      refute Enum.any?(Git.worktree_list(dir), &(Path.expand(&1.path) == wt))
    end
  end

  test "lfs?/1 detects LFS-tracked paths", %{dir: dir} do
    :ok = Git.init(dir)
    refute Git.lfs?(dir)
    write!(dir, ".gitattributes", "*.bin filter=lfs diff=lfs merge=lfs -text\n")
    assert Git.lfs?(dir)
  end
end
