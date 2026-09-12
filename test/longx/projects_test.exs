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
