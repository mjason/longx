defmodule Longx.Agent.Definition.LoaderTest do
  use ExUnit.Case, async: true

  alias Longx.Agent.Definition.Loader
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
             Longx.Agent.Plugs.AgentsMd,
             Longx.Agent.Plugs.Prompt,
             Shell,
             deploy,
             Longx.Agent.Plugs.Jobs,
             Patch,
             Longx.Agent.Plugs.ViewImage,
             Longx.Agent.Plugs.Present,
             Longx.Agent.Plugs.Knowledge,
             Longx.Agent.Plugs.WebSearch,
             Longx.Agent.Plugs.Browser,
             Longx.Agent.Plugs.Credentials,
             Longx.Agent.Plugs.Agents,
             Longx.Agent.Plugs.Watches,
             Longx.Agent.Plugs.Goal,
             Longx.Agent.Plugs.Compaction,
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

  test "a file that vanishes between the listing and its stat (a once watch consumed, a plug the agent removed) is left out, never a crash",
       %{root: root} do
    write!(root, ".longx/local/watches/gone.exs", "x")
    write!(root, ".longx/local/watches/kept.exs", "x")
    path = Path.join(root, ".longx/local/watches/gone.exs")
    kept = Path.join(root, ".longx/local/watches/kept.exs")
    File.rm!(path)
    assert [{^kept, {_mtime, 1}}] = Loader.stamps([path, kept])
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

  test "a plug that handles secrets itself — a port for an OAuth redirect, tokens in a file, keys from the environment — is a notice pointing at Longx.Credentials, not an error",
       %{root: root, tag: tag} do
    write!(
      root,
      ".longx/local/plugs/coros.exs",
      """
      defmodule CorosMcp do
        use Longx.Agent.Plug

        tool :coros_login, "logs in" do
        end

        def coros_login(_args, _ctx) do
          {:ok, socket} = :gen_tcp.listen(8765, [:binary])
          File.write!(".longx/local/coros-mcp/oauth.json", "{}")
          _key = System.get_env("COROS_API_KEY")
          :gen_tcp.close(socket)
          {:ok, "ok"}
        end
      end
      """
    )

    write!(
      root,
      ".longx/local/agent.exs",
      "import Longx.Agent.Config\nagent do\n  plug CorosMcp\nend\n"
    )

    loaded = Loader.load(root, tag: tag, trusted: true)
    assert loaded.errors == []
    assert Enum.any?(names(loaded.plugs), &(inspect(&1) =~ "CorosMcp"))
    assert [notice] = Enum.filter(loaded.notices, &(&1 =~ "coros.exs"))
    assert notice =~ "Longx.Credentials"
    assert notice =~ "listens on a port"
    assert notice =~ "tokens in a file"
    assert notice =~ "key from the environment"
    assert notice =~ "credential_login"
    assert notice =~ "knowledge"
    # the cached layer keeps the notice
    assert Loader.load(root, tag: tag, trusted: true).notices == loaded.notices

    # a plug with none of it gets no notice
    write!(
      root,
      ".longx/local/plugs/coros.exs",
      "defmodule CorosMcp do\n  use Longx.Agent.Plug\nend\n"
    )

    refute Enum.any?(Loader.load(root, tag: tag, trusted: true).notices, &(&1 =~ "coros.exs"))
  end

  test "watches are files of a layer: shared behind the trust switch, local always; a bad head is a notice, the file named",
       %{root: root, tag: tag} do
    write!(root, ".longx/shared/watches/health.exs", """
    defmodule Health do
      use Longx.Agent.Watch
      every "*/5 * * * *"
      def run(ctx), do: {:ok, %{ran: ctx.name}}
    end
    """)

    write!(root, ".longx/local/watches/nightly.exs", """
    defmodule Nightly do
      use Longx.Agent.Watch
      once "2030-01-01T08:00:00+08:00"
      def run(_ctx), do: {:ok, %{}}
    end
    """)

    write!(root, ".longx/local/watches/broken.exs", """
    defmodule Broken do
      use Longx.Agent.Watch
      every "every five minutes"
      def run(_ctx), do: {:ok, %{}}
    end
    """)

    loaded = Loader.load(root, tag: tag, trusted: true)

    assert [%{name: "health", layer: :project}, %{name: "nightly", layer: :local}] =
             Enum.sort_by(loaded.watches, & &1.name)

    [health, nightly] = Enum.sort_by(loaded.watches, & &1.name)
    assert health.path =~ "shared/watches/health.exs"
    assert health.definition.kind == :cron
    assert nightly.definition.kind == :once
    assert Longx.Agent.Watch.watch?(health.module)

    assert %{result: {:ok, %{ran: "health"}}} =
             Longx.Agent.Watch.run(health.module, %{name: "health"})

    # the broken one is a notice naming the file, and not a watch
    assert Enum.any?(loaded.notices, &(&1 =~ "broken.exs" and &1 =~ "cron"))
    refute Enum.any?(loaded.watches, &(&1.name == "broken"))

    # untrusted: the shared watch is not loaded, the local ones are
    untrusted = Loader.load(root, tag: tag, trusted: false)
    assert [%{name: "nightly"}] = untrusted.watches
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

  test "an untrusted project's shared tree is not loaded, its local tree always is; a missing .longx is nothing",
       %{root: root, tag: tag} do
    write!(root, ".longx/plugs/deploy.exs", @deploy)
    write!(root, ".longx/agent.exs", "import Longx.Agent.Config\nagent do\n  plug Deploy\nend\n")
    # what the agent grows on this machine (gitignored) needs no switch: nothing came from a clone
    write!(
      root,
      ".longx/local/agent.exs",
      "import Longx.Agent.Config\nagent do\n  plug Draft\nend\n"
    )

    write!(
      root,
      ".longx/local/plugs/draft.exs",
      "defmodule Draft do\n  use Longx.Agent.Plug\n  instructions \"draft\"\nend\n"
    )

    write!(
      root,
      ".longx/local/agents/helper/agent.exs",
      "import Longx.Agent.Config\nagent do\n  summary \"helps\"\nend\n"
    )

    loaded = Loader.load(root, tag: tag, trusted: false)
    refute Enum.any?(names(loaded.plugs), &String.ends_with?(Atom.to_string(&1), ".Deploy"))
    assert Enum.any?(names(loaded.plugs), &String.ends_with?(Atom.to_string(&1), ".Draft"))
    assert [%{name: "helper", layer: :local}] = loaded.agents
    # the agent is still told about its definition, with the shared tree marked as not loaded
    assert {Longx.Agent.Plugs.Local, opts} =
             Enum.find(loaded.plugs, &match?({Longx.Agent.Plugs.Local, _}, &1))

    assert opts[:trusted] == false
    assert loaded.trusted? == false
    assert loaded.errors == []
    assert loaded.present? == true

    # no .longx yet: the default pipeline, plus the agent told how to grow one
    empty = Loader.load(root <> "-none", tag: tag <> "n", trusted: true)

    assert names(empty.plugs) -- [Longx.Agent.Plugs.Local] ==
             names(Longx.Agent.Pipelines.Default.plugs())

    assert empty.present? == false
  end

  # AGENTS.md is read by default, as codex does; a project that does not want it says so
  test "the shipped pipeline reads AGENTS.md right after the base prompt; a description drops it with `drop AgentsMd`",
       %{root: root, tag: tag} do
    shipped = names(Longx.Agent.Pipelines.Default.plugs())

    assert [Longx.Agent.Plugs.Base, Longx.Agent.Plugs.AgentsMd | _] =
             Enum.drop_while(shipped, &(&1 != Longx.Agent.Plugs.Base))

    write!(
      root,
      ".longx/local/agent.exs",
      "import Longx.Agent.Config\nagent do\n  drop AgentsMd\nend\n"
    )

    loaded = Loader.load(root, tag: tag, trusted: false)
    assert loaded.errors == []
    refute Longx.Agent.Plugs.AgentsMd in names(loaded.plugs)
    assert Longx.Agent.Plugs.Base in names(loaded.plugs)
  end

  test "a role that should not read AGENTS.md drops it in its own description — for itself only: the main agent and the other roles keep it",
       %{root: root, tag: tag} do
    write!(
      root,
      ".longx/local/agents/scout/agent.exs",
      "import Longx.Agent.Config\nagent do\n  summary \"looks around\"\n  drop AgentsMd\n  prompt \"scout rules\"\nend\n"
    )

    write!(
      root,
      ".longx/local/agents/writer/agent.exs",
      "import Longx.Agent.Config\nagent do\n  summary \"writes\"\nend\n"
    )

    main = Loader.load(root, tag: tag, trusted: false)
    scout = Loader.load(root, tag: tag, trusted: false, agent: "scout")
    writer = Loader.load(root, tag: tag, trusted: false, agent: "writer")
    assert scout.errors == []
    # the drop is the scout's own: the main agent and every other role still read AGENTS.md
    assert Longx.Agent.Plugs.AgentsMd in names(main.plugs)
    assert Longx.Agent.Plugs.AgentsMd in names(writer.plugs)
    refute Longx.Agent.Plugs.AgentsMd in names(scout.plugs)

    assert [Longx.Agent.Plugs.Base, Longx.Agent.Plugs.Prompt | _] =
             Enum.drop_while(names(scout.plugs), &(&1 != Longx.Agent.Plugs.Base))

    assert {Longx.Agent.Plugs.Prompt, [text: "scout rules"]} in scout.plugs
  end

  test "shared and local are two layers; local wins; the old flat plugs/ still counts as shared",
       %{root: root, tag: tag} do
    write!(root, ".longx/agent.exs", @agent)
    write!(root, ".longx/shared/plugs/deploy.exs", @deploy)
    write!(root, ".longx/plugs/legacy.exs", String.replace(@deploy, "Deploy", "Legacy"))

    write!(
      root,
      ".longx/local/agent.exs",
      "import Longx.Agent.Config\nagent do\n  model \"my-model\"\n  plug Legacy\n  plug Draft\nend\n"
    )

    write!(
      root,
      ".longx/local/plugs/draft.exs",
      "defmodule Draft do\n  use Longx.Agent.Plug\n  instructions \"draft\"\nend\n"
    )

    loaded = Loader.load(root, tag: tag, trusted: true)
    assert loaded.errors == []
    # the local description applies after the shared one
    assert loaded.model == "my-model"

    labels =
      Enum.map(names(loaded.plugs), &(&1 |> Atom.to_string() |> String.split(".") |> List.last()))

    assert "Deploy" in labels and "Legacy" in labels and "Draft" in labels
    assert Enum.map(loaded.layers, & &1.name) == [:project, :local]
  end

  test "there is no global layer: an agent.exs, a plug or a role next to the global knowledge is never loaded",
       %{root: root, tag: tag} do
    # the global knowledge directory (test config) sits under <data>/agent; nothing there is code
    global = Path.dirname(Longx.Agent.Knowledge.global_dir())
    File.mkdir_p!(Path.join(global, "plugs"))
    File.mkdir_p!(Path.join(global, "agents/ghost"))
    on_exit(fn -> File.rm_rf!(global) end)

    File.write!(
      Path.join(global, "agent.exs"),
      "import Longx.Agent.Config\nagent do\n  plug Ghost\n  model \"ghost-model\"\nend\n"
    )

    File.write!(
      Path.join(global, "plugs/ghost.exs"),
      "defmodule Ghost do\n  use Longx.Agent.Plug\n  instructions \"boo\"\nend\n"
    )

    File.write!(
      Path.join(global, "agents/ghost/agent.exs"),
      "import Longx.Agent.Config\nagent do\n  summary \"a ghost\"\nend\n"
    )

    loaded = Loader.load(root, tag: tag, trusted: true)
    assert loaded.model == nil
    refute Enum.any?(names(loaded.plugs), &String.ends_with?(Atom.to_string(&1), ".Ghost"))
    assert loaded.agents == []
    assert loaded.errors == []
    refute Enum.any?(loaded.layers, &(&1.name == :global))
  end

  @researcher ~S'''
  import Longx.Agent.Config

  agent do
    summary "finds things out on the web and reports"
    model "cheap-model", effort: "low"
    prompt_file "prompt.md"
    drop Longx.Agent.Plugs.Patch
    plug Notes
  end
  '''

  test "a declared agent is a role: its own directory, prompt file and plugs, on top of the project's description",
       %{root: root, tag: tag} do
    write!(
      root,
      ".longx/agent.exs",
      "import Longx.Agent.Config\nagent do\n  prompt \"Project P.\"\nend\n"
    )

    write!(root, ".longx/shared/agents/researcher/agent.exs", @researcher)
    write!(root, ".longx/shared/agents/researcher/prompt.md", "You research.\n")

    write!(
      root,
      ".longx/shared/agents/researcher/plugs/notes.exs",
      "defmodule Notes do\n  use Longx.Agent.Plug\n  instructions \"take notes\"\nend\n"
    )

    main = Loader.load(root, tag: tag, trusted: true)
    assert main.errors == []
    # the roles are known to the main agent, each with a summary; Longx ships none
    assert [
             %{
               name: "researcher",
               summary: "finds things out on the web and reports",
               layer: :project
             }
           ] =
             main.agents

    assert Patch in names(main.plugs)
    assert main.model == nil

    role = Loader.load(root, tag: tag, trusted: true, agent: "researcher")
    assert role.errors == []
    assert role.model == "cheap-model"
    assert role.effort == "low"
    refute Patch in names(role.plugs)
    assert Enum.any?(names(role.plugs), &String.ends_with?(Atom.to_string(&1), ".Notes"))
    # the project's prompt, then the role's: the prompt file becomes prompt text
    prompts = for {Longx.Agent.Plugs.Prompt, [text: t]} <- role.plugs, do: t
    assert prompts == ["Project P.", "You research.\n"]

    # the role is read again on every load — the kernel loads per step — so an edit to its
    # model, level or prompt reaches an agent already running at its next model call
    write!(
      root,
      ".longx/shared/agents/researcher/agent.exs",
      String.replace(@researcher, "cheap-model", "pro")
    )

    File.write!(
      Path.join(root, ".longx/shared/agents/researcher/prompt.md"),
      "You research carefully.\n"
    )

    edited = Loader.load(root, tag: tag, trusted: true, agent: "researcher")
    assert edited.model == "pro"

    assert Enum.any?(
             for({Longx.Agent.Plugs.Prompt, [text: t]} <- edited.plugs, do: t),
             &(&1 =~ "carefully")
           )

    # an unknown role is an error, not a silent main agent
    assert {:error, message} =
             Loader.load(root, tag: tag, trusted: true, agent: "nobody")
             |> then(&{:error, hd(&1.errors).message})

    assert message =~ "nobody"
  end

  test "a local role overrides a shared one of the same name; agents [...] limits who may be spawned; a missing prompt file is an error",
       %{root: root, tag: tag} do
    write!(
      root,
      ".longx/shared/agents/helper/agent.exs",
      "import Longx.Agent.Config\nagent do\n  summary \"shared helper\"\nend\n"
    )

    write!(
      root,
      ".longx/local/agents/helper/agent.exs",
      "import Longx.Agent.Config\nagent do\n  summary \"local helper\"\n  prompt_file \"missing.md\"\nend\n"
    )

    write!(
      root,
      ".longx/agent.exs",
      "import Longx.Agent.Config\nagent do\n  agents [\"helper\", \"reviewer\"]\nend\n"
    )

    loaded = Loader.load(root, tag: tag, trusted: true)

    assert %{summary: "local helper", layer: :local} =
             Enum.find(loaded.agents, &(&1.name == "helper"))

    assert loaded.allowed == ["helper", "reviewer"]
    assert Enum.any?(loaded.errors, &(&1.message =~ "missing.md"))

    plain = Loader.load(root <> "-plain", tag: tag <> "p", trusted: true)
    assert plain.allowed == nil
  end

  test "an older description version is flagged to the model", %{root: root, tag: tag} do
    write!(root, ".longx/agent.exs", "import Longx.Agent.Config\nagent do\n  version 0\nend\n")
    loaded = Loader.load(root, tag: tag, trusted: true)
    assert Enum.any?(loaded.notices, &(&1 =~ "version 0"))
  end
end
