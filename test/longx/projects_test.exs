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
      refute Map.has_key?(project, :dirty_start)
      assert project.web_search == true
      assert project.trust_local_agent == false
      assert project.agent_settings == nil
      assert project.model_id == nil
      assert project.archived_at == nil
    end

    test "init_git: true sets git up as part of creating the project", %{dir: dir} do
      project = Projects.create_project!(%{name: "Fresh", root_path: dir, init_git: true})
      assert %{repository?: true, clean?: true} = Projects.git_info(project)

      # already a repository: nothing to do, no error
      sub = Path.join(dir, "again")
      File.mkdir_p!(sub)
      :ok = Git.init(sub)
      assert %{id: _} = Projects.create_project!(%{name: "Again", root_path: sub, init_git: true})
    end

    test "root_path must be an existing directory and is unique", %{dir: dir} do
      assert {:error, %Ash.Error.Invalid{} = err} =
               Projects.create_project(%{name: "x", root_path: Path.join(dir, "missing")})

      assert Exception.message(err) =~ "existing directory"

      create!(dir)

      assert {:error, %Ash.Error.Invalid{}} =
               Projects.create_project(%{name: "again", root_path: dir})
    end

    test "list / by_slug / update / archive", %{dir: dir} do
      project = create!(dir, %{name: "Listed"})
      assert [%{id: id}] = Projects.list_projects!()
      assert id == project.id
      assert {:ok, %{id: ^id}} = Projects.get_project_by_slug("listed")

      updated = Projects.update_project!(project, %{web_search: false})
      assert updated.web_search == false

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

  describe "deleting a project" do
    test "needs confirm, takes the threads and turns with it, never the directory", %{dir: dir} do
      project = create!(dir)

      thread =
        Projects.create_thread!(%{
          project_id: project.id,
          kernel_thread_id: "native_del_#{System.unique_integer([:positive])}",
          cwd: dir
        })

      Projects.create_turn!(%{
        kernel_turn_id: "turn_del_#{System.unique_integer([:positive])}",
        thread_id: thread.id,
        user_text: "hi",
        started_at: DateTime.utc_now()
      })

      assert {:error, %Ash.Error.Invalid{}} = Projects.delete_project(project)
      assert :ok = Projects.delete_project(project, confirm: true)
      assert Projects.list_projects!(include_archived: true) == []
      assert Ash.read!(Projects.Thread) == []
      assert Ash.read!(Projects.Turn) == []
      assert File.dir?(dir)
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

    test "no git on the machine: the project is created, git is not, and init_git says why", %{
      dir: dir
    } do
      previous = System.get_env("LONGX_GIT")
      System.put_env("LONGX_GIT", "/nonexistent/git")

      on_exit(fn ->
        if previous,
          do: System.put_env("LONGX_GIT", previous),
          else: System.delete_env("LONGX_GIT")
      end)

      project = Projects.create_project!(%{name: "Nogit", root_path: dir, init_git: true})
      assert %{repository?: false} = Projects.git_info(project)
      assert {:error, :no_git} = Projects.init_git(project)
    end

    test "keeps an existing .gitignore", %{dir: dir} do
      File.write!(Path.join(dir, ".gitignore"), "custom/\n")
      {:ok, _} = Projects.init_git(create!(dir))
      assert File.read!(Path.join(dir, ".gitignore")) == "custom/\n"
    end
  end
end
