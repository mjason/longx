defmodule Longx.ProjectsTest do
  use Longx.DataCase, async: false

  alias Longx.Git
  alias Longx.Projects

  setup do
    Ash.bulk_destroy!(Projects.Project, :destroy, %{}, authorize?: false)
    dir = Path.join(System.tmp_dir!(), "longx-project-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp create!(dir, attrs \\ %{}) do
    Projects.create_project!(
      Map.merge(%{name: "Demo #{System.unique_integer([:positive])}", root_path: dir}, attrs)
    )
  end

  describe "projects" do
    test "create normalises the path, derives a slug, and applies defaults", %{dir: dir} do
      project = create!(Path.join(dir, "."), %{name: "My Cool App"})

      assert project.root_path == Path.expand(dir)
      assert project.slug == "my-cool-app"
      assert project.approval_policy == :on_request
      assert project.sandbox == :workspace_write
      assert project.tools == []
      assert project.dirty_start == :commit
      assert project.network_access == false
      assert project.model_id == nil
      assert project.archived_at == nil
    end

    test "root_path must be an existing directory and is unique", %{dir: dir} do
      assert {:error, %Ash.Error.Invalid{} = err} =
               Projects.create_project(%{name: "x", root_path: Path.join(dir, "missing")})

      assert Exception.message(err) =~ "existing directory"

      create!(dir)

      assert {:error, %Ash.Error.Invalid{}} =
               Projects.create_project(%{name: "again", root_path: dir})
    end

    test "tools must be registered", %{dir: dir} do
      assert {:error, %Ash.Error.Invalid{} = err} =
               Projects.create_project(%{name: "x", root_path: dir, tools: ["nope.tool"]})

      assert Exception.message(err) =~ "nope.tool"
      assert %{tools: ["builtin.echo"]} = create!(dir, %{tools: ["builtin.echo"]})
    end

    test "list / by_slug / update / archive", %{dir: dir} do
      project = create!(dir, %{name: "Listed"})
      assert [%{id: id}] = Projects.list_projects!()
      assert id == project.id
      assert {:ok, %{id: ^id}} = Projects.get_project_by_slug("listed")

      updated = Projects.update_project!(project, %{sandbox: :read_only, dirty_start: :off})
      assert updated.sandbox == :read_only
      assert updated.dirty_start == :off

      archived = Projects.archive_project!(project)
      assert %DateTime{} = archived.archived_at
      assert Projects.list_projects!() == []
      assert [%{id: ^id}] = Projects.list_projects!(include_archived: true)
    end

    test "the project's model is validated against the catalogue", %{dir: dir} do
      assert {:error, %Ash.Error.Invalid{}} =
               Projects.create_project(%{
                 name: "x",
                 root_path: dir,
                 model_id: Ash.UUIDv7.generate()
               })
    end
  end

  describe "the project's codex (process + CODEX_HOME)" do
    alias Longx.Codex.Pool

    setup %{dir: dir} do
      project = create!(dir)
      home = Pool.home_dir(project.id)
      on_exit(fn -> Longx.Test.PoolHelpers.stop_pool!([project.id]) && File.rm_rf!(home) end)
      %{project: project, home: home}
    end

    defp fake_home!(home) do
      File.mkdir_p!(Path.join(home, "sessions/2026/09/12"))
      File.write!(Path.join(home, "config.toml"), "# generated\n")
      File.write!(Path.join(home, "state_5.sqlite"), String.duplicate("x", 2_048))
      File.write!(Path.join(home, "thread_history_1.sqlite"), String.duplicate("y", 4_096))
      File.write!(Path.join(home, "sessions/2026/09/12/rollout-1.jsonl"), "{}\n")
    end

    test "codex_info/1 describes the home directory and the worker", %{
      project: project,
      home: home
    } do
      assert %{home: ^home, exists?: false, bytes: 0, files: %{}, worker: :stopped} =
               Projects.codex_info(project)

      fake_home!(home)
      {:ok, conn} = Pool.connection(project.id)
      info = Projects.codex_info(project)
      assert info.exists?
      assert info.bytes > 6_000
      assert info.files["state_5.sqlite"] == 2_048
      assert info.files["thread_history_1.sqlite"] == 4_096
      assert %{pid: ^conn, phase: _, started_at: %DateTime{}} = info.worker
    end

    test "stop_codex/2 and restart_codex/1 drive the worker", %{project: project} do
      {:ok, conn} = Pool.connection(project.id)
      assert :ok = Projects.stop_codex(project)
      assert Pool.status(project.id) == :stopped

      assert {:ok, again} = Projects.restart_codex(project)
      refute again == conn
      assert %{pid: ^again} = Pool.status(project.id)
    end

    test "stop_codex/2 refuses while a turn is running unless forced", %{project: project} do
      {:ok, thread} = Projects.start_thread(project)
      {:ok, _turn} = Projects.send_message(thread, "stall")
      assert {:error, {:turn_in_progress, _}} = Projects.stop_codex(project)
      assert :ok = Projects.stop_codex(project, force: true)
      assert Pool.status(project.id) == :stopped
    end

    test "clear_codex_history/1 wipes codex's state and marks the threads unrecoverable", %{
      project: project,
      home: home
    } do
      fake_home!(home)
      {:ok, thread} = Projects.start_thread(project)

      assert :ok = Projects.clear_codex_history(project)
      assert Pool.status(project.id) == :stopped
      refute File.exists?(Path.join(home, "state_5.sqlite"))
      refute File.exists?(Path.join(home, "sessions"))
      # the config is ours, it stays
      assert File.exists?(Path.join(home, "config.toml"))
      assert Ash.get!(Projects.Thread, thread.id).status == :unrecoverable
    end

    test "reset_codex_home/1 removes the whole directory", %{project: project, home: home} do
      fake_home!(home)
      {:ok, _} = Pool.connection(project.id)
      assert :ok = Projects.reset_codex_home(project)
      refute File.exists?(home)
      assert Pool.status(project.id) == :stopped
    end

    test "archiving stops the worker and keeps the home; deleting needs confirm and removes it",
         %{project: project, home: home} do
      fake_home!(home)
      {:ok, _} = Pool.connection(project.id)

      assert {:ok, _} = Projects.archive_project(project)
      assert Pool.status(project.id) == :stopped
      assert File.exists?(home)

      assert {:error, :confirmation_required} = Projects.delete_project(project)
      assert :ok = Projects.delete_project(project, confirm: true)
      refute File.exists?(home)
      assert {:error, _} = Projects.get_project_by_slug(project.slug)
    end
  end

  describe "git_info/1" do
    test "a directory without git says so", %{dir: dir} do
      project = create!(dir)

      assert %{repository?: false, head: nil, clean?: nil, lfs?: false} =
               Projects.git_info(project)
    end

    test "a repository reports head, cleanliness and lfs", %{dir: dir} do
      :ok = Git.init(dir)
      File.write!(Path.join(dir, "a.txt"), "a")
      {:ok, sha} = Git.commit_all(dir, "first")
      project = create!(dir)

      assert %{repository?: true, head: ^sha, clean?: true, changes: 0, lfs?: false} =
               Projects.git_info(project)

      File.write!(Path.join(dir, "b.txt"), "b")
      assert %{clean?: false, changes: 1} = Projects.git_info(project)
    end

    test "an unborn repository (git init, no commits) is reported as such", %{dir: dir} do
      :ok = Git.init(dir)
      assert %{repository?: true, head: nil} = Projects.git_info(create!(dir))
    end
  end

  describe "init_git/1" do
    test "initialises git with a sensible .gitignore and a first commit", %{dir: dir} do
      File.write!(Path.join(dir, "main.ex"), "IO.puts(:hi)")
      File.mkdir_p!(Path.join(dir, "node_modules/x"))
      File.write!(Path.join(dir, "node_modules/x/index.js"), "1")
      project = create!(dir)

      assert {:ok, %{head: sha}} = Projects.init_git(project)
      assert sha =~ ~r/^[0-9a-f]{40}$/
      assert File.read!(Path.join(dir, ".gitignore")) =~ "node_modules/"
      assert %{repository?: true, clean?: true} = Projects.git_info(project)

      # ignored artefacts were not committed
      {:ok, %{stdout: files}} = Git.run(["ls-files"], cd: dir)
      assert files =~ "main.ex"
      refute files =~ "node_modules"
    end

    test "refuses to touch an existing repository", %{dir: dir} do
      :ok = Git.init(dir)
      assert {:error, :already_a_repository} = Projects.init_git(create!(dir))
    end

    test "keeps an existing .gitignore", %{dir: dir} do
      File.write!(Path.join(dir, ".gitignore"), "custom/\n")
      {:ok, _} = Projects.init_git(create!(dir))
      assert File.read!(Path.join(dir, ".gitignore")) == "custom/\n"
    end
  end
end
