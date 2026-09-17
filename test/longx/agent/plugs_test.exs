defmodule Longx.Agent.PlugsTest do
  use ExUnit.Case, async: true

  alias Longx.Agent.{Context, Step, Tool}
  alias Longx.Agent.Plugs.{AgentsMd, Base, Environment, Patch, Request, Shell, ViewImage}

  setup do
    dir = Path.join(System.tmp_dir!(), "longx-agent-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, ctx: %Context{cwd: dir}}
  end

  defp collect_out(acc) do
    receive do
      {:out, chunk} -> collect_out([chunk | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp tool!(module, name),
    do: Enum.find(module.__agent_tools__(), &(&1.name == name)) || flunk("no tool #{name}")

  describe "Agents" do
    alias Longx.Agent.Plugs.Agents

    @team [
      %{name: "researcher", summary: "finds things out", layer: :longx},
      %{name: "reviewer", summary: "reviews", layer: :longx}
    ]

    defp team_step(assigns) do
      Step.new(
        phase: :request,
        assigns:
          Map.merge(%{agents: @team, allowed: nil, children: [], depth: 0, name: nil}, assigns)
      )
    end

    test "offers the declared roles as spawn_agent's choices, with the protocol in the prompt" do
      step = Agents.call(team_step(%{}), Agents.init([]))
      assert %Tool{schema: schema} = step.tools["spawn_agent"]
      assert schema["properties"]["agent"]["enum"] == ["researcher", "reviewer"]
      text = Enum.join(step.instructions, "\n")
      assert text =~ "researcher — finds things out"
      assert text =~ "[agent <name>]"
      assert text =~ "do not wait"
    end

    test "agents [...] narrows the choices; a role nobody declared is not offered" do
      step = Agents.call(team_step(%{allowed: ["reviewer", "ghost"]}), Agents.init([]))
      assert step.tools["spawn_agent"].schema["properties"]["agent"]["enum"] == ["reviewer"]
    end

    test "at the depth limit or with a full team nothing can be spawned, and the prompt says so" do
      deep = Agents.call(team_step(%{depth: 2}), Agents.init(max_depth: 2))
      refute Map.has_key?(deep.tools, "spawn_agent")
      assert Enum.join(deep.instructions, "\n") =~ "cannot spawn"

      kids = for i <- 1..4, do: %{id: "c#{i}", name: "researcher-#{i}"}
      full = Agents.call(team_step(%{children: kids}), Agents.init(max_children: 4))
      refute Map.has_key?(full.tools, "spawn_agent")
      # the live children can still be spoken to and closed
      assert full.tools["send_message"].schema["properties"]["agent"]["enum"] ==
               Enum.map(kids, & &1.name)

      assert Map.has_key?(full.tools, "close_agent")
    end

    test "with no children there is nobody to message or close" do
      step = Agents.call(team_step(%{}), Agents.init([]))
      refute Map.has_key?(step.tools, "send_message")
      refute Map.has_key?(step.tools, "close_agent")
    end
  end

  describe "Goal" do
    alias Longx.Agent.Plugs.Goal

    defp goal_step(goal, state \\ %{}) do
      Step.new(phase: :turn_end, assigns: %{goal: goal}, state: state)
    end

    test "an active goal continues the turn with the objective; a complete or paused one does not" do
      active = %{"objective" => "ship it", "status" => "active"}
      step = Goal.call(goal_step(active), Goal.init([]))
      assert [{:continue, text}] = step.effects
      assert text =~ "ship it"
      assert text =~ "update_goal"
      assert step.state.goal_rounds == 1

      assert Goal.call(goal_step(%{active | "status" => "complete"}), Goal.init([])).effects == []
      assert Goal.call(goal_step(%{active | "status" => "paused"}), Goal.init([])).effects == []
      assert Goal.call(goal_step(nil), Goal.init([])).effects == []
    end

    test "too many rounds in one turn, or the budget spent, block the goal instead of looping" do
      active = %{"objective" => "ship it", "status" => "active"}
      step = Goal.call(goal_step(active, %{goal_rounds: 8}), Goal.init(max_rounds: 8))
      assert [{:goal, %{"status" => "blocked"}}] = step.effects

      spent = Map.merge(active, %{"tokenBudget" => 100, "tokensUsed" => 120})
      step = Goal.call(goal_step(spent), Goal.init([]))
      assert [{:goal, %{"status" => "blocked"}}] = step.effects
    end

    test "the tools: create, update, get" do
      names = Enum.map(Goal.__agent_tools__(), & &1.name) |> Enum.sort()
      assert names == ["create_goal", "get_goal", "update_goal"]
    end
  end

  describe "Environment" do
    test "names the working directory, the OS and the date", %{dir: dir} do
      step = Environment.call(Step.new(cwd: dir), [])
      [text] = step.instructions
      assert text =~ dir
      assert text =~ "linux"
      assert text =~ Date.to_iso8601(Date.utc_today())
    end
  end

  describe "Base" do
    test "is the base prompt" do
      step = Base.call(Step.new(), [])
      assert [text] = step.instructions
      assert text =~ "You are"
    end
  end

  describe "AgentsMd" do
    test "collects AGENTS.md from the root down to the cwd, nearest last", %{dir: dir} do
      child = Path.join(dir, "sub")
      File.mkdir_p!(child)
      File.write!(Path.join(dir, "AGENTS.md"), "parent rules")
      File.write!(Path.join(child, "AGENTS.md"), "child rules")

      step = AgentsMd.call(Step.new(cwd: child), [])
      [parent, kid] = step.instructions
      assert parent =~ "parent rules"
      assert kid =~ "child rules"
      assert kid =~ Path.join(child, "AGENTS.md")
    end

    test "nothing when there is none", %{dir: dir} do
      assert AgentsMd.call(Step.new(cwd: dir), []).instructions == []
    end
  end

  describe "Shell.exec_command" do
    test "runs the command in the cwd and streams its output", %{dir: dir} do
      me = self()
      ctx = %Context{cwd: dir, emit: &send(me, {:out, &1})}
      tool = tool!(Shell, "exec_command")

      assert tool.show == :command

      assert {:ok, output, %{"exitCode" => 0}} =
               Tool.call(tool, %{"cmd" => "pwd; echo hi >&2"}, ctx)

      assert output =~ dir
      assert output =~ "hi"
      # every chunk was emitted before the call returned
      assert Enum.join(collect_out([])) =~ dir
    end

    test "commands see the person's shell environment, not the BEAM's", %{ctx: ctx} do
      assert {:ok, output, %{"exitCode" => 0}} =
               Tool.call(
                 tool!(Shell, "exec_command"),
                 %{"cmd" => "echo \"$PATH\"; echo \"$HOME\"", "login" => false},
                 ctx
               )

      [path, home | _] = String.split(output, "\n")
      assert path == Longx.Agent.ShellEnv.env()["PATH"]
      assert home == System.get_env("HOME")
    end

    test "a non-zero exit is reported, not an error", %{ctx: ctx} do
      assert {:ok, output, %{"exitCode" => 3}} =
               Tool.call(tool!(Shell, "exec_command"), %{"cmd" => "echo boom; exit 3"}, ctx)

      assert output =~ "boom"
      assert output =~ "exit code 3"
    end

    test "a command past its timeout is killed", %{ctx: ctx} do
      assert {:error, message} =
               Tool.call(
                 tool!(Shell, "exec_command"),
                 # no login shell: its start-up must not eat the budget before "start" prints
                 %{"cmd" => "echo start; sleep 10", "timeout_ms" => 800, "login" => false},
                 ctx
               )

      assert message =~ "timed out"
      assert message =~ "start"
    end
  end

  describe "Patch.apply_patch" do
    test "applies a patch under the cwd and reports the changes for the UI", %{dir: dir, ctx: ctx} do
      File.write!(Path.join(dir, "a.txt"), "one\ntwo\n")
      tool = tool!(Patch, "apply_patch")
      assert tool.show == :file_change
      assert %{syntax: "lark", param: "input"} = tool.freeform

      patch =
        "*** Begin Patch\n*** Add File: b.txt\n+b\n*** Update File: a.txt\n@@\n-two\n+2\n*** End Patch\n"

      assert {:ok, "Done!\n" <> summary, %{"changes" => [add, update]}} =
               Tool.call(tool, %{"input" => patch}, ctx)

      assert summary =~ "A " <> Path.join(dir, "b.txt")
      assert %{"kind" => "add", "diff" => "--- /dev/null" <> _} = add
      assert %{"kind" => "update", "path" => a} = update
      assert a == Path.join(dir, "a.txt")
      assert File.read!(a) == "one\n2\n"

      assert {:error, message} =
               Tool.call(
                 tool,
                 %{
                   "input" =>
                     "*** Begin Patch\n*** Update File: a.txt\n@@\n-nope\n+x\n*** End Patch\n"
                 },
                 ctx
               )

      assert message =~ "nope"
    end
  end

  describe "ViewImage" do
    test "a png becomes a data url the kernel attaches; other files are refused", %{
      dir: dir,
      ctx: ctx
    } do
      png = <<0x89, ?P, ?N, ?G, 13, 10, 26, 10, 0, 0, 0, 0>>
      File.write!(Path.join(dir, "shot.png"), png)
      tool = tool!(ViewImage, "view_image")

      assert {:ok, "attached shot.png", %{"image" => "data:image/png;base64," <> b64}} =
               Tool.call(tool, %{"path" => "shot.png"}, ctx)

      assert Elixir.Base.decode64!(b64) == png
      assert {:error, msg} = Tool.call(tool, %{"path" => "a.txt"}, ctx)
      assert msg =~ "image type"
      assert {:error, msg} = Tool.call(tool, %{"path" => "missing.png"}, ctx)
      assert msg =~ "no such file"
    end
  end

  describe "Request" do
    test "builds the Responses request from the step" do
      tool = %Tool{name: "t", description: "d", fun: fn _, _ -> {:ok, ""} end}

      step =
        Step.new(
          thread_id: "th",
          turn_id: "tu",
          model: "deepseek-flash",
          effort: "low",
          transcript: [%{"type" => "message", "role" => "user", "content" => "hi"}]
        )
        |> Step.instructions("A")
        |> Step.instructions("B")
        |> Step.skill("deploy", "ships it")
        |> Step.tool(tool)
        |> Request.call([])

      assert %{
               "model" => "deepseek-flash",
               "instructions" => instructions,
               "input" => [%{"role" => "user"}],
               "tools" => [%{"type" => "function", "name" => "t"}],
               "reasoning" => %{"effort" => "low", "summary" => "auto"},
               "stream" => true,
               "store" => false,
               "client_metadata" => %{"thread_id" => "th", "turn_id" => "tu"}
             } = step.request

      assert instructions =~ "A\n\nB"
      assert instructions =~ "deploy"
      assert instructions =~ "ships it"
    end

    test "no model means the default (longx) and no reasoning block without a level" do
      step = Request.call(Step.new(), [])
      assert step.request["model"] == "longx"
      refute Map.has_key?(step.request, "reasoning")
      assert step.request["tools"] == []
    end
  end
end
