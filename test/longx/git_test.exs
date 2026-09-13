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

  describe "the changes view: partial commits, per-file diffs, discarding" do
    setup %{dir: dir} do
      :ok = Git.init(dir)
      write!(dir, "a.txt", "one\n")
      write!(dir, "b.txt", "b\n")
      {:ok, base} = Git.commit_all(dir, "base")
      %{base: base}
    end

    test "commit/3 commits only the named paths (untracked ones included); the rest stays changed",
         %{dir: dir} do
      write!(dir, "a.txt", "two\n")
      write!(dir, "c.txt", "new\n")
      File.rm!(Path.join(dir, "b.txt"))

      assert {:ok, sha} = Git.commit(dir, "a and c", paths: ["a.txt", "c.txt"])
      assert [%{sha: ^sha, subject: "a and c"} | _] = Git.log(dir, limit: 1)
      assert Git.status(dir).changes == [%{path: "b.txt", status: :deleted}]

      # a summary with a description becomes subject + body
      assert {:ok, sha2} = Git.commit(dir, "drop b\n\nit was empty", paths: ["b.txt"])
      assert %{subject: "drop b", body: "it was empty"} = Git.show(dir, sha2)
      assert Git.status(dir).clean?

      assert {:error, :nothing_to_commit} = Git.commit(dir, "nothing", paths: ["a.txt"])
    end

    test "file_diff/2 for a modified, an untracked and a deleted file; binaries are flagged", %{
      dir: dir
    } do
      write!(dir, "a.txt", "two\n")
      write!(dir, "c.txt", "new\n")
      File.rm!(Path.join(dir, "b.txt"))
      write!(dir, "pic.png", <<137, 80, 78, 71, 0, 1, 2, 3>>)

      assert %{binary: false, diff: diff} = Git.file_diff(dir, "a.txt")
      assert diff =~ "-one" and diff =~ "+two"
      assert %{binary: false, diff: diff} = Git.file_diff(dir, "c.txt")
      assert diff =~ "+new"
      assert %{binary: false, diff: diff} = Git.file_diff(dir, "b.txt")
      assert diff =~ "-b"
      assert %{binary: true} = Git.file_diff(dir, "pic.png")
    end

    test "file_versions/3 gives both sides of a working-tree change: HEAD's text and the file now",
         %{
           dir: dir
         } do
      write!(dir, "a.txt", "two\n")
      write!(dir, "c.txt", "new\n")
      File.rm!(Path.join(dir, "b.txt"))
      write!(dir, "pic.png", <<137, 80, 78, 71, 0, 1, 2, 3>>)

      assert %{before: "one\n", after: "two\n", binary: false} =
               Git.file_versions(dir, nil, "a.txt")

      assert %{before: nil, after: "new\n"} = Git.file_versions(dir, nil, "c.txt")
      assert %{before: "b\n", after: nil} = Git.file_versions(dir, nil, "b.txt")
      assert %{binary: true, before: nil, after: nil} = Git.file_versions(dir, nil, "pic.png")
    end

    test "discard/2 puts tracked files back and removes untracked ones, only the named paths", %{
      dir: dir
    } do
      write!(dir, "a.txt", "two\n")
      write!(dir, "c.txt", "new\n")
      write!(dir, "d.txt", "keep me\n")
      File.rm!(Path.join(dir, "b.txt"))

      assert :ok = Git.discard(dir, ["a.txt", "c.txt", "b.txt"])
      assert File.read!(Path.join(dir, "a.txt")) == "one\n"
      assert File.read!(Path.join(dir, "b.txt")) == "b\n"
      refute File.exists?(Path.join(dir, "c.txt"))
      assert Git.status(dir).changes == [%{path: "d.txt", status: :untracked}]
    end
  end

  describe "the history view" do
    setup %{dir: dir} do
      :ok = Git.init(dir)
      write!(dir, "a.txt", "one\n")
      {:ok, s1} = Git.commit_all(dir, "one")
      write!(dir, "a.txt", "two\n")
      write!(dir, "b.txt", "b\n")
      {:ok, s2} = Git.commit_all(dir, "two\n\nwith a body")
      %{s1: s1, s2: s2}
    end

    test "log/2 pages with skip and knows the author's email", %{dir: dir, s1: s1, s2: s2} do
      assert [%{sha: ^s2, email: email}] = Git.log(dir, limit: 1)
      assert email =~ "@"
      assert [%{sha: ^s1}] = Git.log(dir, limit: 1, skip: 1)
      assert [] = Git.log(dir, limit: 1, skip: 2)
    end

    test "show/2 has the message, the author and the files the commit touched", %{
      dir: dir,
      s1: s1,
      s2: s2
    } do
      assert %{
               sha: ^s2,
               subject: "two",
               body: "with a body",
               author: _,
               email: _,
               at: %DateTime{},
               parents: [^s1],
               files: files
             } =
               Git.show(dir, s2)

      assert files == [%{path: "a.txt", status: :modified}, %{path: "b.txt", status: :added}]
      # the root commit has no parent; its files are additions
      assert %{parents: [], files: [%{path: "a.txt", status: :added}]} = Git.show(dir, s1)
      assert {:error, _} = Git.show(dir, "0000000")
    end

    test "a merge commit lists what it brought in (against its first parent)", %{dir: dir} do
      :ok = Git.create_branch(dir, "topic")
      write!(dir, "c.txt", "c\n")
      {:ok, topic} = Git.commit_all(dir, "topic work")
      main = Git.branches(dir).branches |> Enum.find(&(&1.name != "topic")) |> Map.fetch!(:name)
      :ok = Git.switch(dir, main)
      {:ok, _} = Git.run(["merge", "--no-ff", "-q", "-m", "merge topic", "topic"], cd: dir)
      {:ok, merge} = Git.head(dir)

      assert %{parents: [_, ^topic], files: [%{path: "c.txt", status: :added}]} =
               Git.show(dir, merge)

      assert %{diff: diff} = Git.commit_file_diff(dir, merge, "c.txt")
      assert diff =~ "+c"
    end

    test "commit_file_diff/3 shows what one commit did to one file, the root commit too", %{
      dir: dir,
      s1: s1,
      s2: s2
    } do
      assert %{binary: false, diff: diff} = Git.commit_file_diff(dir, s2, "a.txt")
      assert diff =~ "-one" and diff =~ "+two"
      assert %{diff: diff} = Git.commit_file_diff(dir, s1, "a.txt")
      assert diff =~ "+one"
    end

    test "file_versions/3 for a commit: the file before it (its first parent) and after; nothing before the root",
         %{dir: dir, s1: s1, s2: s2} do
      assert %{before: "one\n", after: "two\n", binary: false} =
               Git.file_versions(dir, s2, "a.txt")

      assert %{before: nil, after: "one\n"} = Git.file_versions(dir, s1, "a.txt")
      assert %{before: nil, after: "b\n"} = Git.file_versions(dir, s2, "b.txt")
    end

    test "undo_commit/1 takes the last commit back into the working tree; the root commit cannot be undone",
         %{dir: dir, s1: s1} do
      assert {:ok, ^s1} = Git.undo_commit(dir)
      assert %{changes: changes} = Git.status(dir)
      assert %{path: "a.txt", status: :modified} in changes
      assert %{path: "b.txt", status: :added} in changes
      {:ok, _} = Git.commit_all(dir, "two again")
      {:ok, _} = Git.undo_commit(dir)
      assert {:error, :root_commit} = Git.undo_commit(dir)
    end
  end

  describe "branches" do
    setup %{dir: dir} do
      :ok = Git.init(dir)
      write!(dir, "a.txt", "one\n")
      {:ok, base} = Git.commit_all(dir, "base")
      %{base: base}
    end

    test "branches/1 lists them with the current one marked; create, switch, delete", %{
      dir: dir,
      base: base
    } do
      assert %{
               current: current,
               branches: [%{name: current, sha: ^base, current: true, upstream: nil}]
             } = Git.branches(dir)

      assert :ok = Git.create_branch(dir, "feature/x")
      assert %{current: "feature/x"} = Git.branches(dir)
      assert :ok = Git.switch(dir, current)
      assert %{current: ^current, branches: branches} = Git.branches(dir)
      assert Enum.map(branches, & &1.name) |> Enum.sort() == Enum.sort([current, "feature/x"])

      assert :ok = Git.delete_branch(dir, "feature/x")
      assert [%{name: ^current}] = Git.branches(dir).branches
      assert {:error, %Git.Error{}} = Git.switch(dir, "nope")
      assert {:error, %Git.Error{}} = Git.create_branch(dir, "bad name")
    end

    test "switching with changes in the way: stash, switch, and the stash can come back", %{
      dir: dir
    } do
      :ok = Git.create_branch(dir, "other")
      write!(dir, "a.txt", "changed on other\n")
      {:ok, _} = Git.commit_all(dir, "other")

      :ok =
        Git.switch(
          dir,
          Git.branches(dir).branches |> Enum.find(&(&1.name != "other")) |> Map.fetch!(:name)
        )

      write!(dir, "a.txt", "wip\n")
      assert {:error, %Git.Error{}} = Git.switch(dir, "other")
      assert :ok = Git.stash(dir, "wip on main")
      assert Git.status(dir).clean?
      assert :ok = Git.switch(dir, "other")
      assert [%{message: message}] = Git.stashes(dir)
      assert message =~ "wip on main"

      :ok =
        Git.switch(
          dir,
          Git.branches(dir).branches |> Enum.find(&(&1.name != "other")) |> Map.fetch!(:name)
        )

      assert :ok = Git.stash_pop(dir)
      assert File.read!(Path.join(dir, "a.txt")) == "wip\n"
      assert [] = Git.stashes(dir)
    end
  end

  describe "ignored paths and merges in progress" do
    setup %{dir: dir} do
      :ok = Git.init(dir)
      write!(dir, ".gitignore", "build/\n*.log\n")
      write!(dir, "a.txt", "one\n")
      {:ok, _} = Git.commit_all(dir, "base")
      :ok
    end

    test "ignored/1 names what .gitignore hides (directories as a whole)", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "build/out"))
      write!(dir, "build/out/x.js", "x")
      write!(dir, "debug.log", "l")
      write!(dir, "b.txt", "b")
      assert Git.ignored(dir) == ["build/", "debug.log"]
    end

    test "a pull that conflicts leaves a merge in progress: the files are unmerged, the merge can be committed (after editing) or aborted",
         %{dir: dir} do
      :ok = Git.create_branch(dir, "theirs")
      write!(dir, "a.txt", "theirs\n")
      {:ok, _} = Git.commit_all(dir, "theirs")
      main = Git.branches(dir).branches |> Enum.find(&(&1.name != "theirs")) |> Map.fetch!(:name)
      :ok = Git.switch(dir, main)
      write!(dir, "a.txt", "ours\n")
      {:ok, _} = Git.commit_all(dir, "ours")

      assert {:error, %Git.Error{}} = Git.run(["merge", "-q", "theirs"], cd: dir)
      assert Git.merging?(dir)
      assert %{changes: [%{path: "a.txt", status: :unmerged}]} = Git.status(dir)
      assert %{diff: diff} = Git.file_diff(dir, "a.txt")
      assert diff =~ "<<<<<<<" or diff =~ "ours"

      # resolved by hand, then committed: a merge is committed whole, never partially
      write!(dir, "a.txt", "both\n")
      assert {:ok, sha} = Git.commit(dir, "merge theirs", paths: ["a.txt"])
      assert %{parents: [_, _]} = Git.show(dir, sha)
      refute Git.merging?(dir)

      # or abandoned
      write!(dir, "a.txt", "ours again\n")
      {:ok, _} = Git.commit_all(dir, "ours again")
      :ok = Git.switch(dir, "theirs")
      write!(dir, "a.txt", "theirs again\n")
      {:ok, _} = Git.commit_all(dir, "theirs again")
      :ok = Git.switch(dir, main)
      assert {:error, _} = Git.run(["merge", "-q", "theirs"], cd: dir)
      assert Git.merging?(dir)
      assert :ok = Git.abort_merge(dir)
      refute Git.merging?(dir)
      assert File.read!(Path.join(dir, "a.txt")) == "ours again\n"
    end
  end

  describe "remotes (a bare repository on disk plays the server)" do
    setup %{dir: dir} do
      remote =
        Path.join(System.tmp_dir!(), "longx-git-remote-#{System.unique_integer([:positive])}")

      File.mkdir_p!(remote)
      {:ok, _} = Git.run(["init", "-q", "--bare"], cd: remote)
      on_exit(fn -> File.rm_rf!(remote) end)
      :ok = Git.init(dir)
      write!(dir, "a.txt", "one\n")
      {:ok, base} = Git.commit_all(dir, "base")
      %{remote: remote, base: base}
    end

    test "remotes/1, set_remote/3, push, fetch, pull and ahead/behind", %{
      dir: dir,
      remote: remote
    } do
      assert Git.remotes(dir) == []
      assert :ok = Git.set_remote(dir, "origin", remote)
      assert [%{name: "origin", url: ^remote}] = Git.remotes(dir)
      assert Git.ahead_behind(dir) == nil

      # first push sets the upstream
      assert :ok = Git.push(dir)
      assert Git.ahead_behind(dir) == %{ahead: 0, behind: 0}
      assert %{branches: [%{upstream: "origin/" <> _}]} = Git.branches(dir)

      write!(dir, "a.txt", "two\n")
      {:ok, _} = Git.commit_all(dir, "two")
      assert Git.ahead_behind(dir) == %{ahead: 1, behind: 0}
      assert :ok = Git.push(dir)
      assert Git.ahead_behind(dir) == %{ahead: 0, behind: 0}

      # someone else pushes: fetch sees it, pull takes it
      other =
        Path.join(System.tmp_dir!(), "longx-git-other-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(other) end)
      {:ok, _} = Git.run(["clone", "-q", remote, other])
      write!(other, "b.txt", "from other\n")
      {:ok, _} = Git.commit_all(other, "other")
      :ok = Git.push(other)

      assert :ok = Git.fetch(dir)
      assert Git.ahead_behind(dir) == %{ahead: 0, behind: 1}
      assert :ok = Git.pull(dir)
      assert Git.ahead_behind(dir) == %{ahead: 0, behind: 0}
      assert File.read!(Path.join(dir, "b.txt")) == "from other\n"

      # an unreachable remote is an error, not a hang
      :ok = Git.set_remote(dir, "origin", Path.join(remote, "gone"))
      assert {:error, %Git.Error{}} = Git.fetch(dir)
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
