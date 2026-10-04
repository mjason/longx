defmodule Longx.Agent.SkillsTest do
  use ExUnit.Case, async: true

  alias Longx.Agent.{Skills, Step, Tool}
  alias Longx.Agent.Plugs.Skills, as: SkillsPlug

  setup do
    dir = Path.join(System.tmp_dir!(), "longx-skills-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, ".git"))
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp skill(dir, folder, name, description, body \\ "WORKFLOW_SECRET") do
    path = Path.join([dir, ".agents", "skills", folder, "SKILL.md"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "---\nname: #{name}\ndescription: #{description}\n---\n#{body}")
    path
  end

  test "real YAML, fallback name, normalized block description, independent errors", %{dir: dir} do
    path = skill(dir, "deploy", "", ">\n  Ship safely:\n  test first")
    skill(dir, "broken", "broken", "")
    snapshot = Skills.snapshot(dir)

    assert [%{name: "deploy", description: "Ship safely: test first", path: ^path}] =
             snapshot.skills

    refute Map.has_key?(hd(snapshot.skills), :body)
    assert [_] = snapshot.warnings
  end

  test "discover root to cwd only; same names remain distinct; no project root means cwd only",
       %{dir: dir} do
    root = skill(dir, "root", "build", "root build")
    child = Path.join(dir, "apps/web")
    nested = skill(child, "local", "build", "local build")
    snapshot = Skills.snapshot(child)
    assert Enum.map(snapshot.skills, & &1.path) == [root, nested]
    assert Enum.map(Skills.snapshot(child, root_markers: []).skills, & &1.path) == [nested]
  end

  test "explicit names refuse ambiguity; structured path wins; disabled paths never fall back",
       %{dir: dir} do
    a = skill(dir, "a", "build", "A")
    b = skill(dir, "b", "build", "B")
    snapshot = Skills.snapshot(dir)
    assert {[], [warning]} = Skills.select(snapshot, [%{text: "$build"}])
    assert warning =~ "ambiguous"
    assert {[%{path: ^b}], []} = Skills.select(snapshot, [%{skills: [b], text: "$build"}])
    disabled = Skills.snapshot(dir, disabled: [b])
    assert {[], [_]} = Skills.select(disabled, [%{skills: [b], text: "$build"}])
    assert {[%{path: ^a}], []} = Skills.select(disabled, [%{text: "$build $build $HOME"}])
  end

  test "optional metadata is fail-open; explicit-only skills are not implicit catalog entries",
       %{dir: dir} do
    path = skill(dir, "deploy", "deploy", "Ships")
    metadata = Path.join(Path.dirname(path), "agents/openai.yaml")
    File.mkdir_p!(Path.dirname(metadata))
    File.write!(metadata, "policy:\n  allow_implicit_invocation: false\n")
    snapshot = Skills.snapshot(dir)
    refute Skills.catalog(snapshot, 8_000) =~ "- deploy:"
    assert {[%{name: "deploy"}], []} = Skills.select(snapshot, [%{text: "$deploy"}])
    File.write!(metadata, "policy: [broken")
    assert [%{implicit: true}] = Skills.snapshot(dir).skills
  end

  test "canonical dedup, symlink cycle and outside-project links are bounded", %{dir: dir} do
    path = skill(dir, "a", "a", "A")
    File.ln_s!("a", Path.join(dir, ".agents/skills/alias"))
    File.ln_s!(".", Path.join(dir, ".agents/skills/loop"))
    File.ln_s!("/etc", Path.join(dir, ".agents/skills/outside"))
    snapshot = Skills.snapshot(dir)
    assert [%{path: ^path}] = snapshot.skills
    assert Enum.any?(snapshot.warnings, &String.contains?(&1, "outside"))

    assert {[%{path: ^path}], []} =
             Skills.select(snapshot, [
               %{skills: [Path.join(dir, ".agents/skills/alias/SKILL.md")]}
             ])
  end

  test "resource reads stay inside the selected skill, never execute scripts, never truncate",
       %{dir: dir} do
    path = skill(dir, "a", "a", "A", String.duplicate("文", 4_000))
    [entry] = Skills.snapshot(dir).skills
    script = Path.join(Path.dirname(path), "scripts/run.sh")
    File.mkdir_p!(Path.dirname(script))
    File.write!(script, "touch SHOULD_NOT_EXIST")
    assert {:ok, body} = Skills.read(entry)
    assert body =~ String.duplicate("文", 4_000)
    assert {:ok, "touch SHOULD_NOT_EXIST"} = Skills.read(entry, "scripts/run.sh")
    refute File.exists?(Path.join(dir, "SHOULD_NOT_EXIST"))
    assert {:error, _} = Skills.read(entry, "../a/../other/SKILL.md")
    File.ln_s!("/etc/passwd", Path.join(Path.dirname(path), "escape"))
    assert {:error, _} = Skills.read(entry, "escape")
  end

  test "catalog budget is UTF-8 safe and omissions visible; scan limits visible", %{dir: dir} do
    for n <- 1..5, do: skill(dir, "#{n}", "s#{n}", String.duplicate("文", 500))
    catalog = Skills.catalog(Skills.snapshot(dir), 300)
    assert String.valid?(catalog)
    assert String.length(catalog) <= 300
    assert catalog =~ "omitted"
    assert [_ | _] = Skills.snapshot(dir, max_dirs: 1).warnings
  end

  test "default plug is removable; prompt and on-demand tool mount only in request", %{dir: dir} do
    path = skill(dir, "a", "a", "A")
    assert {SkillsPlug, []} in Longx.Agent.Pipelines.Default.plugs()
    config = %Longx.Agent.Config{ops: [{:drop, SkillsPlug}]}

    refute Enum.any?(
             Longx.Agent.Config.resolve(Longx.Agent.Pipelines.Default.plugs(), config),
             &(elem(&1, 0) == SkillsPlug)
           )

    step = Step.new(cwd: dir)
    mounted = SkillsPlug.call(step, SkillsPlug.init([])) |> Longx.Agent.Plugs.Request.call([])
    assert mounted.request["instructions"] =~ path
    refute mounted.request["instructions"] =~ "WORKFLOW_SECRET"

    assert {:ok, "read skill a\n" <> _} =
             Tool.call(mounted.tools["skill_read"], %{"path" => path}, %{})

    assert SkillsPlug.call(%{step | phase: :response}, SkillsPlug.init([])) == %{
             step
             | phase: :response
           }
  end

  test "Skills occupies Codex's capability slot after tools and before multi-agent guidance",
       %{dir: dir} do
    skill(dir, "a", "a", "A")
    File.write!(Path.join(dir, "AGENTS.md"), "PROJECT_INSTRUCTIONS_MARKER")
    config = %Longx.Agent.Config{prompts: ["ROLE_INSTRUCTIONS_MARKER"]}

    plugs =
      Longx.Agent.Config.resolve(Longx.Agent.Pipelines.Default.plugs(), config)

    modules = Enum.map(plugs, &elem(&1, 0))
    slot = Enum.find_index(modules, &(&1 == SkillsPlug))
    assert Enum.at(modules, slot - 1) == Longx.Agent.Plugs.Credentials
    assert Enum.at(modules, slot + 1) == Longx.Agent.Plugs.Agents

    # Use distinct markers to test the actual Request result, not just its
    # configured module order. Keep the real Skills and Request transforms.
    step =
      Enum.reduce(plugs, Step.new(cwd: dir), fn
        {SkillsPlug, opts}, step ->
          SkillsPlug.call(step, SkillsPlug.init(opts))

        {Longx.Agent.Plugs.Request, opts}, step ->
          Longx.Agent.Plugs.Request.call(step, opts)

        {module, opts}, step
        when module in [Longx.Agent.Plugs.AgentsMd, Longx.Agent.Plugs.Prompt] ->
          module.call(step, module.init(opts))

        {module, _opts}, step ->
          Step.instructions(step, "PLUGIN:#{inspect(module)}")
      end)

    prompt = step.request["instructions"]

    position = fn text ->
      {at, _} = :binary.match(prompt, text)
      at
    end

    assert position.("PROJECT_INSTRUCTIONS_MARKER") < position.("ROLE_INSTRUCTIONS_MARKER")

    assert position.("ROLE_INSTRUCTIONS_MARKER") <
             position.("PLUGIN:Longx.Agent.Plugs.Credentials")

    assert position.("PLUGIN:Longx.Agent.Plugs.Credentials") < position.("## Skills")
    assert position.("## Skills") < position.("- Trigger rules:")
    assert position.("- Trigger rules:") < position.("PLUGIN:Longx.Agent.Plugs.Agents")
  end

  test "explicit body is in first request, snapshot stable during turn, fresh next turn",
       %{dir: dir} do
    path = skill(dir, "a", "a", "A")
    opts = SkillsPlug.init([])
    first = SkillsPlug.call(Step.new(cwd: dir, state: %{user_inputs: [%{text: "$a"}]}), opts)
    request = Longx.Agent.Plugs.Request.call(first, []).request
    assert Jason.encode!(request["input"]) =~ "WORKFLOW_SECRET"
    assert [{:context, _, _}] = first.effects
    File.write!(path, "---\nname: a\ndescription: CHANGED\n---\nNEW_BODY")

    second =
      SkillsPlug.call(Step.new(cwd: dir, state: first.state, transcript: first.transcript), opts)

    assert Enum.join(second.instructions) =~ "- a: A"
    refute Enum.join(second.instructions) =~ "CHANGED"
    assert second.transcript == first.transcript
    assert second.effects == []
    fresh = SkillsPlug.call(Step.new(cwd: dir), opts)
    assert Enum.join(fresh.instructions) =~ "CHANGED"
    refute Jason.encode!(fresh.transcript) =~ "NEW_BODY"
  end

  test "Codex usage prompt alignment has only the documented filesystem substitutions" do
    source = File.read!("test/support/fixtures/codex_skills_usage.md")

    expected =
      source
      |> String.replace(
        "name + description + short path",
        "name + description + absolute path"
      )
      |> String.replace(
        "Skill bodies live on disk at the listed paths after expanding the matching alias from `### Skill roots`.",
        "Skill bodies live on disk at the listed paths."
      )
      |> String.replace(
        "the main agent must expand the listed short `path` with the matching alias from `### Skill roots`, then open and read",
        "the main agent must open and read"
      )
      |> String.replace(
        "that expanded `SKILL.md`",
        "that `SKILL.md`"
      )

    assert SkillsPlug.prompt() == String.trim(expected)
  end

  test "plain YAML scalar containing a colon is repaired like Codex; unknown fields tolerated" do
    assert {:ok, %{name: "build", description: "Build for AWS: ECS"}} =
             Skills.parse(
               "---\nname: build\ndescription: Build for AWS: ECS\nextra: ignored\n---\nbody",
               "fallback"
             )

    assert {:error, _} =
             Skills.parse("---\nname: [not, a, name]\ndescription: D\n---\nbody", "fallback")
  end

  test "optional malformed policy values fail open instead of crashing", %{dir: dir} do
    path = skill(dir, "a", "a", "A")
    optional = Path.join(Path.dirname(path), "agents/openai.yaml")
    File.mkdir_p!(Path.dirname(optional))

    for text <- ["policy: false", "policy: []", "policy:\n  allow_implicit_invocation: nonsense"] do
      File.write!(optional, text)
      assert [%{implicit: true}] = Skills.snapshot(dir).skills
    end
  end
end
