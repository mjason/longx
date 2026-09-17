defmodule Longx.Agent.LoaderTest do
  use ExUnit.Case, async: true

  alias Longx.Agent.Loader
  alias Longx.Agent.Plugs.{Base, Environment, Patch, Request, Shell}

  setup do
    n = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "longx-loader-#{n}")
    File.mkdir_p!(Path.join(root, ".longx/plugs"))
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, tag: "T#{n}"}
  end

  defp write!(root, rel, text) do
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, text)
    # mtimes have one-second resolution: a rewrite in the same second must still count
    File.touch!(path, System.os_time(:second) + System.unique_integer([:positive, :monotonic]))
  end

  @deploy ~S'''
  defmodule Deploy do
    use Longx.Agent.Plug

    instructions "Deploy with the deploy tool."

    tool :deploy, "ships the branch" do
      param :env, :string, "target", required: true
    end

    def deploy(%{"env" => env}, _ctx), do: {:ok, "deployed to #{env}"}
  end
  '''

  @agent ~S'''
  import Longx.Agent.Config

  agent do
    version 1
    extends :default
    model "fake-model", effort: "low"
    prompt "This is a demo project."
    plug Deploy, after: Shell
    drop Longx.Agent.Plugs.Base
  end
  '''

  defp names(plugs), do: Enum.map(plugs, fn {m, _} -> m end)

  test "a project's plugs are compiled under the layer's namespace and mounted where the description says",
       %{root: root, tag: tag} do
    write!(root, ".longx/plugs/deploy.exs", @deploy)
    write!(root, ".longx/agent.exs", @agent)

    loaded = Loader.load(root, tag: tag, trusted: true)

    deploy = Module.concat([Longx.Agent.Local, tag, Deploy])
    assert loaded.errors == []
    assert loaded.model == "fake-model"
    assert loaded.effort == "low"

    assert names(loaded.plugs) == [
             Environment,
             Shell,
             deploy,
             Patch,
             Longx.Agent.Plugs.ViewImage,
             Longx.Agent.Plugs.Prompt,
             Longx.Agent.Plugs.Local,
             Request
           ]

    refute Base in names(loaded.plugs)
    assert [%{name: "deploy"}] = deploy.__agent_tools__()
    assert {Longx.Agent.Plugs.Prompt, [text: "This is a demo project."]} in loaded.plugs
  end

  test "two layers may define the same module name", %{root: root, tag: tag} do
    other = root <> "-other"
    File.mkdir_p!(Path.join(other, ".longx/plugs"))
    on_exit(fn -> File.rm_rf!(other) end)

    write!(root, ".longx/plugs/deploy.exs", @deploy)
    write!(root, ".longx/agent.exs", "import Longx.Agent.Config\nagent do\n  plug Deploy\nend\n")
    write!(other, ".longx/plugs/deploy.exs", String.replace(@deploy, "deployed to", "shipped to"))
    write!(other, ".longx/agent.exs", "import Longx.Agent.Config\nagent do\n  plug Deploy\nend\n")

    a = Loader.load(root, tag: tag, trusted: true)
    b = Loader.load(other, tag: tag <> "b", trusted: true)

    [ma] = Enum.filter(names(a.plugs), &String.ends_with?(Atom.to_string(&1), ".Deploy"))
    [mb] = Enum.filter(names(b.plugs), &String.ends_with?(Atom.to_string(&1), ".Deploy"))
    assert ma != mb
    assert {:ok, "deployed to x"} = ma.deploy(%{"env" => "x"}, %{})
    assert {:ok, "shipped to x"} = mb.deploy(%{"env" => "x"}, %{})
  end

  test "a change on disk is picked up on the next load", %{root: root, tag: tag} do
    write!(root, ".longx/plugs/deploy.exs", @deploy)
    write!(root, ".longx/agent.exs", "import Longx.Agent.Config\nagent do\n  plug Deploy\nend\n")
    first = Loader.load(root, tag: tag, trusted: true)
    deploy = Module.concat([Longx.Agent.Local, tag, Deploy])
    assert deploy in names(first.plugs)
    assert [%{name: "deploy"}] = deploy.__agent_tools__()

    write!(
      root,
      ".longx/plugs/deploy.exs",
      String.replace(@deploy, ":deploy", ":ship") |> String.replace("def deploy", "def ship")
    )

    second = Loader.load(root, tag: tag, trusted: true)
    assert deploy in names(second.plugs)
    assert [%{name: "ship"}] = deploy.__agent_tools__()

    # unchanged files are not recompiled
    third = Loader.load(root, tag: tag, trusted: true)
    assert third.plugs == second.plugs
  end

  test "a broken file is a notice for the model, not a dead agent", %{root: root, tag: tag} do
    write!(
      root,
      ".longx/plugs/bad.exs",
      "defmodule Bad do\n  use Longx.Agent.Plug\n  def call(step, _) do step\nend\n"
    )

    write!(
      root,
      ".longx/agent.exs",
      "import Longx.Agent.Config\nagent do\n  drop Longx.Agent.Plugs.Base\nend\n"
    )

    loaded = Loader.load(root, tag: tag, trusted: true)
    assert [%{file: file, message: message}] = loaded.errors
    assert file =~ "bad.exs"
    assert message =~ "bad.exs"
    # the description itself still applied
    refute Base in names(loaded.plugs)
    assert Enum.any?(loaded.notices, &(&1 =~ "bad.exs"))

    write!(root, ".longx/agent.exs", "1 + 1\n")
    loaded = Loader.load(root, tag: tag, trusted: true)
    assert Enum.any?(loaded.errors, &(&1.message =~ "agent description"))
    # the layer below stands
    assert Base in names(loaded.plugs)
  end

  test "an untrusted project is not loaded; a missing .longx is nothing", %{root: root, tag: tag} do
    write!(root, ".longx/plugs/deploy.exs", @deploy)
    write!(root, ".longx/agent.exs", "import Longx.Agent.Config\nagent do\n  plug Deploy\nend\n")
    loaded = Loader.load(root, tag: tag, trusted: false)
    refute Enum.any?(names(loaded.plugs), &String.ends_with?(Atom.to_string(&1), ".Deploy"))
    refute Longx.Agent.Plugs.Local in names(loaded.plugs)
    assert loaded.errors == []
    assert loaded.present? == true

    empty = Loader.load(root <> "-none", tag: tag <> "n", trusted: true)
    assert names(empty.plugs) == names(Longx.Agent.Pipelines.Default.plugs())
    assert empty.present? == false
  end

  test "an older description version is flagged to the model", %{root: root, tag: tag} do
    write!(root, ".longx/agent.exs", "import Longx.Agent.Config\nagent do\n  version 0\nend\n")
    loaded = Loader.load(root, tag: tag, trusted: true)
    assert Enum.any?(loaded.notices, &(&1 =~ "version 0"))
  end
end
