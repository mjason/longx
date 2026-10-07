defmodule Longx.Projects.ExtensionsTest do
  use Longx.DataCase, async: false

  alias Longx.Projects
  alias Longx.Projects.Extensions

  setup do
    root = Path.join(System.tmp_dir!(), "longx-extensions-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    project = Projects.create_project!(%{name: "Extensions", root_path: root})
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, project: project}
  end

  defp put(root, path, text) do
    full = Path.join(root, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, text)
  end

  test "inventory groups roles and runs, not hundreds of individual artifacts", %{
    root: root,
    project: project
  } do
    put(root, ".longx/local/agents/helper/agent.exs", """
    import Longx.Agent.Config
    agent do
      version 1
      summary "Test helper"
      prompt_file "prompt.md"
      agents []
    end
    """)

    put(root, ".longx/local/agents/helper/prompt.md", "prompt")

    put(root, ".longx/local/plugs/check.exs", """
    defmodule ExtensionsTestCheck do
      use Longx.Agent.Plug
    end
    """)

    put(root, ".longx/shared/knowledge/design/guide.md", "doc")
    put(root, ".longx/local/artifacts/e2e/run-one/test.db", "database")
    put(root, ".longx/local/artifacts/e2e/run-one/screenshot.png", <<0, 1>>)
    put(root, ".longx/local/artifacts/e2e/run-two/report.json", "{}")
    put(root, ".longx/local/random.json", "not an extension")

    items = Projects.list_project_extensions!(project.id)
    assert Enum.count(items, &(&1.kind == "agents")) == 1
    assert Enum.count(items, &(&1.kind == "artifacts")) == 2
    refute Enum.any?(items, &String.ends_with?(&1.path, ".png"))
    refute Enum.any?(items, &(&1.name == "random.json"))
    assert Enum.all?(Enum.filter(items, &(&1.kind == "artifacts")), &(not &1.shareable))

    refute Enum.any?(
             Projects.agent_definition(project).local_files,
             &String.starts_with?(&1, "artifacts/")
           )
  end

  test "role preview contains prompt and dependencies; confirmed share moves the whole role", %{
    root: root,
    project: project
  } do
    put(root, ".longx/local/agents/helper/agent.exs", "definition")
    put(root, ".longx/local/agents/helper/prompt.md", "prompt")
    put(root, ".longx/local/agents/helper/knowledge/rules.md", "rules")
    preview = Projects.preview_project_extension!(project.id, "agents/helper/agent.exs")
    assert preview.path == "agents/helper"
    assert length(preview.files) == 3
    assert preview.can_share

    assert {:ok, "shared/agents/helper"} =
             Projects.promote_local(project, preview.path, preview.digest)

    assert File.read!(Path.join(root, ".longx/shared/agents/helper/prompt.md")) == "prompt"
    refute File.exists?(Path.join(root, ".longx/local/agents/helper"))
  end

  test "existing targets and changed content cannot be silently replaced", %{
    root: root,
    project: project
  } do
    put(root, ".longx/local/plugs/check.exs", "first")
    preview = Projects.preview_project_extension!(project.id, "plugs/check.exs")
    put(root, ".longx/local/plugs/check.exs", "changed")
    assert {:error, _} = Projects.promote_local(project, preview.path, preview.digest)
    assert File.read!(Path.join(root, ".longx/local/plugs/check.exs")) == "changed"
    preview = Projects.preview_project_extension!(project.id, "plugs/check.exs")
    put(root, ".longx/shared/plugs/check.exs", "shared")
    assert {:error, _} = Projects.promote_local(project, preview.path, preview.digest)
    conflict = Projects.preview_project_extension!(project.id, "plugs/check.exs")
    refute conflict.can_share
    assert conflict.conflicts == [".longx/shared/plugs/check.exs"]
    assert File.read!(Path.join(root, ".longx/shared/plugs/check.exs")) == "shared"
  end

  test "artifacts, definitions, traversal and symlinks are not share candidates", %{root: root} do
    put(root, ".longx/local/artifacts/report.md", "report")
    put(root, ".longx/local/agent.exs", "override")

    for path <- ["artifacts/report.md", "agent.exs", "../escape", "/tmp/x", "plugs/../x.exs"] do
      assert {:error, _} = Extensions.preview(root, path)
    end

    put(root, "outside.exs", "outside")
    File.mkdir_p!(Path.join(root, ".longx/local/plugs"))
    File.ln_s!(Path.join(root, "outside.exs"), Path.join(root, ".longx/local/plugs/link.exs"))
    assert {:error, _} = Extensions.preview(root, "plugs/link.exs")
    refute Enum.any?(Extensions.inventory(root), &(&1.name == "link.exs"))
    put(root, ".longx/local/plugs/valid.exs", "valid")
    File.mkdir_p!(Path.join(root, "outside"))
    File.mkdir_p!(Path.join(root, ".longx/shared"))
    File.ln_s!(Path.join(root, "outside"), Path.join(root, ".longx/shared/plugs"))
    assert {:error, _} = Extensions.preview(root, "plugs/valid.exs")
  end

  test "sharing needs a reviewed digest and a complete role", %{root: root, project: project} do
    put(root, ".longx/local/agents/incomplete/prompt.md", "only a prompt")
    assert {:error, _} = Extensions.preview(root, "agents/incomplete")
    put(root, ".longx/local/plugs/check.exs", "check")
    assert {:error, _} = Projects.promote_local(project, "plugs/check.exs")
    refute File.exists?(Path.join(root, ".longx/shared/plugs/check.exs"))
  end

  test "previews are bounded and reject symlink descendants", %{root: root} do
    put(root, ".longx/local/agents/large/agent.exs", "definition")
    put(root, ".longx/local/agents/large/large.bin", :binary.copy(<<0>>, 16 * 1024 * 1024))
    assert {:error, message} = Extensions.preview(root, "agents/large")
    assert message =~ "too large"

    put(root, ".longx/local/agents/linked/agent.exs", "definition")
    put(root, "external/prompt.md", "outside")
    File.ln_s!(Path.join(root, "external"), Path.join(root, ".longx/local/agents/linked/data"))
    assert {:error, _} = Extensions.preview(root, "agents/linked")
  end

  test "extension directory browsing rejects traversal and hides symlinks", %{root: root} do
    put(root, ".longx/local/artifacts/run-one/report.md", "report")
    put(root, "outside/secret.md", "outside")
    File.ln_s!(Path.join(root, "outside"), Path.join(root, ".longx/local/artifacts/link"))
    assert {:error, _} = Extensions.list_files(root, ".longx/../outside")
    assert {:error, _} = Extensions.list_files(root, ".longx/local/artifacts/link")
    assert {:ok, files} = Extensions.list_files(root, ".longx/local/artifacts")
    assert Enum.map(files, & &1.name) == ["run-one"]
  end
end
