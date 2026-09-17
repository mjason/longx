defmodule Longx.Agent.Definition.ConfigTest do
  use ExUnit.Case, async: true

  alias Longx.Agent.Config
  alias Longx.Agent.Plugs.{Base, Environment, Patch, Request, Shell}

  import Longx.Agent.Config

  @default [{Environment, []}, {Base, []}, {Shell, []}, {Patch, []}, {Request, []}]

  test "the DSL is data: a description of what to change" do
    config =
      agent do
        version 1
        extends :default
        model "deepseek-flash", effort: "low"
        prompt "Phoenix app; run mix test after edits."
        plug MyDeploy, env: "staging"
        plug MyGuard, before: Request
        options Shell, timeout_ms: 300_000
        drop Base
      end

    assert %Config{version: 1, extends: :default, model: "deepseek-flash", effort: "low"} = config
    assert config.prompts == ["Phoenix app; run mix test after edits."]

    assert config.ops == [
             {:plug, MyDeploy, [env: "staging"], nil},
             {:plug, MyGuard, [], {:before, Request}},
             {:options, Shell, [timeout_ms: 300_000]},
             {:drop, Base}
           ]

    assert config.pipeline == nil
  end

  test "a role describes itself: summary, prompt_file, and who it may spawn" do
    config =
      agent do
        summary "reviews diffs"
        prompt_file "prompt.md"
        agents ["researcher"]
      end

    assert %Config{summary: "reviews diffs", prompt_files: ["prompt.md"], agents: ["researcher"]} =
             config

    assert %Config{agents: nil} = agent(do: version(1))
  end

  test "an explicit pipeline replaces the base wholesale" do
    config =
      agent do
        pipeline do
          plug Environment
          plug Request
        end
      end

    assert config.pipeline == [{Environment, []}, {Request, []}]
    assert Config.resolve(@default, config) == [{Environment, []}, {Request, []}]
  end

  test "resolve/2 applies the ops to the base: insert (before Request by default), position, options, drop" do
    config =
      agent do
        extends :default
        plug MyDeploy, env: "staging"
        plug MyGuard, after: Environment
        options Shell, timeout_ms: 300_000
        drop Base
        prompt "extra"
      end

    assert Config.resolve(@default, config) == [
             {Environment, []},
             {MyGuard, []},
             {Shell, [timeout_ms: 300_000]},
             {Patch, []},
             {MyDeploy, [env: "staging"]},
             {Longx.Agent.Plugs.Prompt, [text: "extra"]},
             {Request, []}
           ]
  end

  test "layers stack: a later description applies to the result of the earlier ones" do
    project =
      agent do
        drop Patch
        plug Later
      end

    global =
      agent do
        options Shell, timeout_ms: 1
      end

    resolved = @default |> Config.resolve(global) |> Config.resolve(project)

    assert resolved == [
             {Environment, []},
             {Base, []},
             {Shell, [timeout_ms: 1]},
             {Later, []},
             {Request, []}
           ]
  end

  test "the current format version is known; an older description is flagged" do
    assert Config.current_version() >= 1
    assert Config.outdated?(%Config{version: 0})
    refute Config.outdated?(%Config{version: Config.current_version()})
  end
end
