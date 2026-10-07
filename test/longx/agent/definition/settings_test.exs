defmodule Longx.Agent.Definition.SettingsTest do
  use Longx.DataCase, async: false

  alias Longx.Agent.Definition.{Loader, Settings}
  alias Longx.Agent.Plugs.Agents
  alias Longx.Agent.Tools.ShellEnv
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
    default_path = default_obscura_path()

    assert %{
             max_depth: 2,
             max_children: 4,
             idle_minutes: 30,
             child_model: nil,
             command_shell: "auto",
             extra_path: ^default_path
           } =
             Settings.global()

    # no reviewer role ships with the kernel, so no reviewer model either
    refute :reviewer_model in Settings.fields()
    refute Map.has_key?(Settings.defaults(), :reviewer_model)

    assert {:ok, %{max_depth: 3, idle_minutes: 5}} =
             Settings.put_global(%{max_depth: 3, idle_minutes: 5})

    assert %{max_depth: 3, max_children: 4, idle_minutes: 5} = Settings.global()

    assert {:ok, %{extra_path: "/opt/tools\n/usr/local/bin"}} =
             Settings.put_global(%{extra_path: "/opt/tools\n/usr/local/bin"})

    assert "/opt/tools" in String.split(ShellEnv.env()["PATH"], ":")
    assert "/usr/local/bin" in String.split(ShellEnv.env()["PATH"], ":")
    assert {:ok, %{extra_path: ""}} = Settings.put_global(%{extra_path: ""})

    refute default_obscura_path() in String.split(ShellEnv.env()["PATH"], ":")
    assert {:ok, %{extra_path: ^default_path}} = Settings.put_global(%{extra_path: nil})

    assert {:ok, %{extra_path: ^default_path}} =
             Settings.put_global(%{extra_path: default_path})

    refute Map.has_key?(Settings.global_overrides(), :extra_path)

    assert default_path in String.split(ShellEnv.env()["PATH"], ":")

    if System.find_executable("bash") do
      assert {:ok, %{command_shell: "bash"}} = Settings.put_global(%{command_shell: "bash"})
      assert ShellEnv.shell() == System.find_executable("bash")

      assert Settings.for_project(%{agent_settings: %{command_shell: "zsh"}}).command_shell ==
               "bash"
    end

    assert {:ok, %{command_shell: "auto"}} = Settings.put_global(%{command_shell: nil})
    assert {:error, %{field: :command_shell}} = Settings.put_global(%{command_shell: "fish"})

    # the machine's guards on commands: OOM priority and the memory floor
    assert %{command_oom_priority: 800, memory_floor_percent: 8} =
             Settings.global()

    assert {:ok, %{memory_floor_percent: 20}} =
             Settings.put_global(%{memory_floor_percent: 20})

    assert {:error, %{field: :command_oom_priority}} =
             Settings.put_global(%{command_oom_priority: 1001})

    assert {:error, %{field: :memory_floor_percent}} =
             Settings.put_global(%{memory_floor_percent: 51})

    assert {:ok, _} = Settings.put_global(%{memory_floor_percent: nil})

    assert {:error, %{field: :max_children}} = Settings.put_global(%{max_children: 0})
    assert {:error, %{field: :child_model}} = Settings.put_global(%{child_model: "no-such-model"})
    # nil clears a value back to the default
    assert {:ok, %{max_depth: 2}} = Settings.put_global(%{max_depth: nil})
  end

  @tag :cgroup
  test "command cgroup mode validates auto, off and required with project inheritance" do
    assert Settings.defaults().command_cgroup_mode == "auto"

    assert {:ok, %{command_cgroup_mode: "off"}} =
             Settings.put_global(%{command_cgroup_mode: "off"})

    assert Settings.for_project(%{agent_settings: %{}}).command_cgroup_mode == "off"

    assert Settings.for_project(%{agent_settings: %{"command_cgroup_mode" => "required"}}).command_cgroup_mode ==
             "required"

    assert {:error, %{field: :command_cgroup_mode}} =
             Settings.put_global(%{command_cgroup_mode: "always"})

    assert {:ok, %{command_cgroup_mode: "auto"}} =
             Settings.put_global(%{command_cgroup_mode: nil})

    assert Loader.command_guard_options(
             %{Settings.defaults() | command_cgroup_mode: "off"},
             {:linux, :x86_64},
             100_000
           )[:cgroup] == :off

    assert Loader.command_guard_options(
             %{Settings.defaults() | command_cgroup_mode: "required"},
             {:linux, :x86_64},
             100_000
           )[:cgroup] == :required
  end

  @tag :cgroup
  test "task cgroup budgets have validated defaults, zero swap and project overrides" do
    assert %{command_memory_limit_percent: 75, command_swap_limit_mb: 1024} =
             Settings.defaults()

    assert {:ok, %{command_memory_limit_percent: 80, command_swap_limit_mb: 0}} =
             Settings.put_global(%{command_memory_limit_percent: 80, command_swap_limit_mb: 0})

    for value <- [0, 81, 1.5] do
      assert {:error, %{field: :command_memory_limit_percent}} =
               Settings.put_global(%{command_memory_limit_percent: value})
    end

    for value <- [-1, 65537, 1.5] do
      assert {:error, %{field: :command_swap_limit_mb}} =
               Settings.put_global(%{command_swap_limit_mb: value})
    end

    assert %{command_memory_limit_percent: 30, command_swap_limit_mb: 0} =
             Settings.for_project(%{agent_settings: %{"command_memory_limit_percent" => 30}})

    assert {:ok, %{command_memory_limit_percent: 75, command_swap_limit_mb: 1024}} =
             Settings.put_global(%{command_memory_limit_percent: nil, command_swap_limit_mb: nil})
  end

  @tag :cgroup
  test "loader converts Linux limits to bytes and leaves other operating systems unchanged" do
    settings = Settings.defaults()
    linux = Loader.command_guard_options(settings, {:linux, :x86_64}, 100_000)
    assert linux[:cgroup] == :auto
    assert linux[:memory_max] == 75_000
    assert linux[:swap_max] == 1024 * 1024 * 1024

    zero =
      Loader.command_guard_options(
        Map.put(settings, :command_swap_limit_mb, 0),
        {:linux, :aarch64},
        100_000
      )

    assert zero[:swap_max] == 0

    for platform <- [{:darwin, :aarch64}, {:windows, :x86_64}] do
      other = Loader.command_guard_options(settings, platform, nil)
      refute Keyword.has_key?(other, :cgroup)
      refute Keyword.has_key?(other, :memory_max)
      refute Keyword.has_key?(other, :swap_max)
    end
  end

  defp default_obscura_path do
    case Longx.Browser.Runtime.executable() do
      {:ok, executable} ->
        Path.dirname(executable)

      {:error, :not_installed} ->
        case Longx.Browser.Runtime.current_target() do
          nil ->
            nil

          target ->
            Longx.Browser.Runtime.root(Longx.Browser.Runtime.dir(), target)
        end
    end
  end

  test "a project's overrides sit on the global ones", %{dir: dir} do
    {:ok, _} = Settings.put_global(%{max_children: 6})
    project = Projects.create_project!(%{name: "S", root_path: dir})
    assert %{max_children: 6, max_depth: 2} = Settings.for_project(project)

    {:ok, project} =
      Projects.update_project(project, %{agent_settings: %{max_depth: 1, idle_minutes: 1}})

    assert %{max_children: 6, max_depth: 1, idle_minutes: 1} = Settings.for_project(project)
    assert Settings.for_project_id(project.id) == Settings.for_project(project)
    assert Settings.idle_ms(Settings.for_project(project)) == 60_000
  end

  test "the loader turns the settings into the topmost layer: limits on the Agents plug, the default child model",
       %{dir: dir, tag: tag} do
    # the project declares the roles; Longx ships none
    for role <- ["coder", "reviewer"] do
      File.mkdir_p!(Path.join(dir, ".longx/shared/agents/#{role}"))

      File.write!(
        Path.join(dir, ".longx/shared/agents/#{role}/agent.exs"),
        "import Longx.Agent.Config\nagent do\n  summary \"#{role}\"\nend\n"
      )
    end

    settings = %{
      Settings.defaults()
      | max_depth: 3,
        max_children: 1,
        child_model: "kid",
        child_effort: "high"
    }

    main = Loader.load(dir, tag: tag, trusted: true, settings: settings)
    assert {Agents, opts} = Enum.find(main.plugs, &match?({Agents, _}, &1))
    assert opts[:max_depth] == 3 and opts[:max_children] == 1
    # the command guards reach the Shell plug as its options
    assert {Longx.Agent.Plugs.Shell, shell} =
             Enum.find(main.plugs, &match?({Longx.Agent.Plugs.Shell, _}, &1))

    assert shell[:oom_score_adj] == 800 and shell[:memory_floor_percent] == 8

    # the main agent keeps whatever the person chose: no model from the settings
    assert main.model == nil

    # a child without a model of its own gets the default child model
    coder = Loader.load(dir, tag: tag, trusted: true, settings: settings, agent: "coder")
    assert coder.model == "kid"

    # a role named reviewer is a role like any other: the child model, level included
    reviewer = Loader.load(dir, tag: tag, trusted: true, settings: settings, agent: "reviewer")
    assert reviewer.model == "kid" and reviewer.effort == "high"

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

    assert "plugs/x.exs" in definition.local_files
    assert "agents/helper/agent.exs" in definition.local_files
    assert definition.settings.max_depth == 2

    assert {:ok, preview} = Projects.preview_project_extension(project.id, "plugs/x.exs")

    assert {:ok, "shared/plugs/x.exs"} =
             Projects.promote_local(project, "plugs/x.exs", preview.digest)

    assert File.exists?(Path.join(dir, ".longx/shared/plugs/x.exs"))
    assert {:error, _} = Projects.promote_local(project, "../escape")
    assert {:error, _} = Projects.promote_local(project, "plugs/x.exs")
  end
end
