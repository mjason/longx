defmodule Longx.Projects.FileWatchTest do
  @moduledoc """
  What Longx ignores in a project (`FileRules`: the built-in lists, the global
  and the project's settings, .gitignore, .longxignore — later over earlier)
  and the file watcher that runs only while a page has the project open.
  """
  use Longx.DataCase, async: false

  alias Longx.Projects
  alias Longx.Projects.{FileRules, Watcher}

  setup do
    dir = Path.join(System.tmp_dir!(), "longx-fw-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    project =
      Projects.create_project!(%{
        name: "FW #{System.unique_integer([:positive])}",
        root_path: dir
      })

    :ok = Phoenix.PubSub.subscribe(Longx.PubSub, Projects.topic(project.id))

    on_exit(fn ->
      Watcher.stop(project.id)
      Longx.Test.TmpDirs.rm_rf!(dir)
    end)

    %{project: project, dir: dir}
  end

  defp write!(dir, rel, content \\ "x") do
    path = Path.join(dir, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  # the batch that names `path` (the watcher coalesces; others may come first)
  defp assert_changed(id, path, timeout \\ 3_000) do
    receive do
      {:files_changed, ^id, paths} ->
        if path in paths, do: paths, else: assert_changed(id, path, timeout)
    after
      timeout -> flunk("no files_changed naming #{path}")
    end
  end

  describe "the rules" do
    test "stack the built-in lists, the global and the project's settings; .gitignore only in a repository",
         %{project: project, dir: dir} do
      {:ok, _} = FileRules.put_global(%{ignore: "logs/\n# a comment\n", watch: "keep-me/\n"})

      {:ok, project} =
        Projects.update_project(project, %{
          file_rules: %{"ignore" => "data/", "watch" => "data/keep/"}
        })

      config = FileRules.config(project)
      assert config.root == dir
      assert "node_modules/" in config.ignore
      # built in, then global, then the project's
      assert Enum.take(config.ignore, -2) == ["logs/", "data/"]
      assert ".longx/" in config.watch
      assert Enum.take(config.watch, -2) == ["keep-me/", "data/keep/"]
      refute config.git

      :ok = Longx.Git.init(dir)
      assert FileRules.config(project).git
    end

    test "what the tree dims: an ignored directory whole, a brought-back one only itself",
         %{project: project, dir: dir} do
      :ok = Longx.Git.init(dir)
      write!(dir, ".gitignore", "target/\n")
      write!(dir, ".longxignore", "!target/reports/\n")
      write!(dir, "node_modules/x.js")
      write!(dir, "target/other.bin")
      write!(dir, "target/reports/r.txt")
      write!(dir, "src/a.py")

      assert {:ok, ignored} = FileRules.ignored(project)
      assert Enum.sort(ignored) == ["node_modules/", "target", "target/other.bin"]
    end
  end

  describe "the watcher" do
    test "starts with the first page, reports changes by kind, and leaves with the last page — its process gone too",
         %{project: project, dir: dir} do
      :ok = Longx.Git.init(dir)
      write!(dir, ".gitignore", ".longx/\n")
      refute Watcher.whereis(project.id)

      page = spawn(fn -> Process.sleep(:infinity) end)
      assert {:ok, pid, %{watching: true}} = Watcher.subscribe(project.id, page)
      assert Watcher.whereis(project.id) == pid

      write!(dir, "src/a.py")
      assert_changed(project.id, "src/a.py")

      # gitignored, still watched: the agent description
      write!(dir, ".longx/local/agent.exs", "agent do end")
      assert_receive {:definition_changed, id}, 3_000
      assert id == project.id

      write!(dir, ".git/HEAD", "ref: refs/heads/other\n")
      assert_receive {:git_changed, ^id}, 3_000

      os_pid = Watcher.os_pid(project.id)
      ref = Process.monitor(pid)
      Process.exit(page, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 3_000
      refute Watcher.whereis(project.id)
      # the shim saw its stdin close and exited
      assert eventually(fn -> not os_alive?(os_pid) end)
    end

    test "stays while another page still has the project open", %{project: project} do
      one = spawn(fn -> Process.sleep(:infinity) end)
      two = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, pid, _} = Watcher.subscribe(project.id, one)
      {:ok, ^pid, _} = Watcher.subscribe(project.id, two)
      Process.exit(one, :kill)
      Process.sleep(300)
      assert Watcher.whereis(project.id) == pid
      Process.exit(two, :kill)
    end

    test "a changed project setting reloads the rules", %{project: project, dir: dir} do
      page = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, _, _} = Watcher.subscribe(project.id, page)
      write!(dir, "gen/a.txt")
      assert_changed(project.id, "gen/a.txt")

      {:ok, _} = Projects.update_project(project, %{file_rules: %{"ignore" => "gen/"}})
      assert_receive {:files_changed, _, []}, 3_000
      write!(dir, "gen/b.txt")
      write!(dir, "src/c.txt")
      paths = assert_changed(project.id, "src/c.txt")
      refute "gen/b.txt" in paths
      Process.exit(page, :kill)
    end
  end

  defp os_alive?(os_pid),
    do: match?({_, 0}, System.cmd("kill", ["-0", "#{os_pid}"], stderr_to_stdout: true))

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(50)
        eventually(fun, tries - 1)
    end
  end
end
