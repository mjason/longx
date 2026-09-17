defmodule Longx.Agent.SettingsTest do
  use Longx.DataCase, async: false

  alias Longx.Agent.{Loader, Settings}
  alias Longx.Agent.Plugs.Agents
  alias Longx.Projects

  setup do
    Ash.bulk_destroy!(Longx.System.Setting, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(Projects.Project, :destroy, %{}, authorize?: false)
    n = System.unique_integer([:positive])
    dir = Path.join(System.tmp_dir!(), "longx-settings-#{n}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, tag: "S#{n}"}
  end

  test "the global settings start at the defaults, are saved as one setting and validated" do
    assert %{
             max_depth: 2,
             max_children: 4,
             idle_minutes: 30,
             child_model: nil,
             reviewer_model: nil
           } =
             Settings.global()

    assert {:ok, %{max_depth: 3, idle_minutes: 5}} =
             Settings.put_global(%{max_depth: 3, idle_minutes: 5})

    assert %{max_depth: 3, max_children: 4, idle_minutes: 5} = Settings.global()

    assert {:error, %{field: :max_children}} = Settings.put_global(%{max_children: 0})
    assert {:error, %{field: :child_model}} = Settings.put_global(%{child_model: "no-such-model"})
    # nil clears a value back to the default
    assert {:ok, %{max_depth: 2}} = Settings.put_global(%{max_depth: nil})
  end

  test "a project's overrides sit on the global ones", %{dir: dir} do
    {:ok, _} = Settings.put_global(%{max_children: 6})
    project = Projects.create_project!(%{name: "S", root_path: dir, engine: :native})
    assert %{max_children: 6, max_depth: 2} = Settings.for_project(project)

    {:ok, project} =
      Projects.update_project(project, %{agent_settings: %{max_depth: 1, idle_minutes: 1}})

    assert %{max_children: 6, max_depth: 1, idle_minutes: 1} = Settings.for_project(project)
    assert Settings.for_project_id(project.id) == Settings.for_project(project)
    assert Settings.idle_ms(Settings.for_project(project)) == 60_000
  end

  test "the loader turns the settings into the topmost layer: limits on the Agents plug, default child and reviewer models",
       %{dir: dir, tag: tag} do
    settings = %{
      Settings.defaults()
      | max_depth: 3,
        max_children: 1,
        child_model: "kid",
        reviewer_model: "judge",
        reviewer_effort: "high"
    }

    main = Loader.load(dir, tag: tag, settings: settings)
    assert {Agents, opts} = Enum.find(main.plugs, &match?({Agents, _}, &1))
    assert opts[:max_depth] == 3 and opts[:max_children] == 1
    # the main agent keeps whatever the person chose: no model from the settings
    assert main.model == nil

    # a child without a model of its own gets the default child model
    coder = Loader.load(dir, tag: tag, settings: settings, agent: "coder")
    assert coder.model == "kid"

    # the reviewer role runs on the reviewer model, level included
    reviewer = Loader.load(dir, tag: tag, settings: settings, agent: "reviewer")
    assert reviewer.model == "judge" and reviewer.effort == "high"

    # a role that declares its model keeps it
    File.mkdir_p!(Path.join(dir, ".longx/shared/agents/picky"))

    File.write!(
      Path.join(dir, ".longx/shared/agents/picky/agent.exs"),
      "import Longx.Agent.Config\nagent do\n  model \"own\"\nend\n"
    )

    picky = Loader.load(dir, tag: tag, trusted: true, settings: settings, agent: "picky")
    assert picky.model == "own"
  end

  test "promotion moves a local plug, agent or doc into the shared tree; the definition lists roles and local files",
       %{dir: dir} do
    project =
      Projects.create_project!(%{
        name: "P",
        root_path: dir,
        engine: :native,
        trust_local_agent: true
      })

    File.mkdir_p!(Path.join(dir, ".longx/local/plugs"))
    File.mkdir_p!(Path.join(dir, ".longx/local/agents/helper"))

    File.write!(
      Path.join(dir, ".longx/local/plugs/x.exs"),
      "defmodule X do\n  use Longx.Agent.Plug\nend\n"
    )

    File.write!(
      Path.join(dir, ".longx/local/agents/helper/agent.exs"),
      "import Longx.Agent.Config\nagent do\n  summary \"helps\"\nend\n"
    )

    definition = Projects.agent_definition(project)

    assert %{name: "helper", summary: "helps", layer: "local"} =
             Enum.find(definition.agents, &(&1.name == "helper"))

    assert Enum.any?(definition.agents, &(&1.name == "researcher" and &1.layer == "longx"))
    assert "plugs/x.exs" in definition.local_files
    assert "agents/helper/agent.exs" in definition.local_files
    assert definition.settings.max_depth == 2

    assert {:ok, "shared/plugs/x.exs"} = Projects.promote_local(project, "plugs/x.exs")
    assert File.exists?(Path.join(dir, ".longx/shared/plugs/x.exs"))
    assert {:error, _} = Projects.promote_local(project, "../escape")
    assert {:error, _} = Projects.promote_local(project, "plugs/x.exs")
  end
end
