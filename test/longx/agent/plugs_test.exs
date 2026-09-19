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

  # the test's emit tags its messages {:emitted, _}: exec_command's own receive loop
  # takes {:out, _} for the shim's output, and an emit shaped the same was swallowed
  defp collect_out(acc) do
    receive do
      {:emitted, chunk} -> collect_out([chunk | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp tool!(module, name),
    do: Enum.find(module.__agent_tools__(), &(&1.name == name)) || flunk("no tool #{name}")

  describe "Present" do
    alias Longx.Agent.Plugs.Present

    @present Jason.decode!(File.read!(Path.join(:code.priv_dir(:longx), "agent/present.json")))

    test "a tool may be declared with a raw JSON schema" do
      tool =
        Tool.declare(__MODULE__, :draw, "draws", [],
          schema: %{"type" => "object", "properties" => %{"x" => %{"type" => "integer"}}}
        )

      assert tool.schema == %{
               "type" => "object",
               "properties" => %{"x" => %{"type" => "integer"}}
             }

      assert {:error, "invalid arguments: " <> _} = Tool.validate(tool.schema, %{"x" => "no"})
    end

    test "present and prompt_user carry the vocabulary's schema from priv/agent/present.json, in the longx namespace" do
      present = tool!(Present, "present")
      assert present.namespace == "longx"
      assert present.schema == @present["present"]["parameters"]
      assert present.description == @present["present"]["description"]
      assert "Table" in present.schema["properties"]["$type"]["enum"]

      prompt = tool!(Present, "prompt_user")
      assert prompt.namespace == "longx"
      assert prompt.schema == @present["prompt_user"]["parameters"]
      # the person may take a while: the tool waits as long as the ask does
      assert prompt.timeout >= 600_000
    end

    test "present answers the model briefly; the tree itself is what the person sees", %{ctx: ctx} do
      tree = %{
        "$type" => "Card",
        "title" => "Q3",
        "children" => [%{"$type" => "Fact", "label" => "a", "value" => "1"}]
      }

      assert {:ok, "shown to the user"} = Tool.call(tool!(Present, "present"), tree, ctx)
      # an unknown component is refused by the schema before anything shows
      assert {:error, "invalid arguments: " <> _} =
               Tool.call(tool!(Present, "present"), %{"$type" => "Rocket"}, ctx)
    end

    test "a tree the model serialised badly is normalised before validation: children / rows as a JSON string, the whole tree under a key",
         %{ctx: ctx} do
      # 百炼 / DeepSeek send nested arrays as strings now and then — the card
      # then showed its children as one raw JSON text
      stringly = %{
        "$type" => "Card",
        "title" => "凭证",
        "children" =>
          Jason.encode!([
            %{"$type" => "Text", "value" => "hi"},
            %{
              "$type" => "Table",
              "columns" => Jason.encode!([%{"label" => "k"}]),
              "rows" => Jason.encode!([["a"]])
            }
          ])
      }

      assert %{
               "children" => [
                 %{"$type" => "Text"},
                 %{"$type" => "Table", "columns" => [%{"label" => "k"}], "rows" => [["a"]]}
               ]
             } =
               Present.normalize(stringly)

      # the tool sees the normalised tree (Tool.call and the kernel's arguments_of both apply it)
      tool = tool!(Present, "present")
      assert {:ok, "shown to the user"} = Tool.call(tool, stringly, ctx)

      assert %{"children" => [_, _]} =
               Longx.Agent.Kernel.Calls.arguments_of(
                 %{"arguments" => Jason.encode!(stringly)},
                 tool
               )

      # the whole tree wrapped in a key, or serialised as one string
      inner = %{"$type" => "Button", "label" => "ok"}
      assert Present.normalize(%{"spec" => inner}) == inner
      assert Present.normalize(%{"tree" => Jason.encode!(inner)}) == inner
      # a component's text under the wrong prop (an Alert once drew as an empty
      # pill: its words were in `text`, the vocabulary reads `title` / `description`)
      assert %{"$type" => "Alert", "description" => "watch out", "tone" => "warning"} =
               Present.normalize(%{
                 "$type" => "Alert",
                 "text" => "watch out",
                 "tone" => "warning"
               })

      assert %{"$type" => "Alert", "title" => "T", "description" => "D"} =
               Present.normalize(%{"$type" => "Alert", "title" => "T", "message" => "D"})

      assert %{"$type" => "Text", "value" => "hi"} =
               Present.normalize(%{"$type" => "Text", "text" => "hi"})

      assert %{"$type" => "Header", "text" => "hi"} =
               Present.normalize(%{"$type" => "Header", "value" => "hi"})

      assert %{"$type" => "Markdown", "value" => "# hi"} =
               Present.normalize(%{"$type" => "Markdown", "content" => "# hi"})

      # the right prop present: the others are left as they are
      assert %{"$type" => "Text", "value" => "v", "text" => "t"} =
               Present.normalize(%{"$type" => "Text", "value" => "v", "text" => "t"})

      # a Text whose value happens to look like JSON stays text
      text = %{"$type" => "Text", "value" => ~s({"not": "a tree"})}
      assert Present.normalize(text) == text
      # a proper tree is untouched
      tree = %{
        "$type" => "Card",
        "children" => [%{"$type" => "Fact", "label" => "a", "value" => "1"}]
      }

      assert Present.normalize(tree) == tree
    end

    test "prompt_user outside an agent cannot ask", %{ctx: ctx} do
      assert {:error, "no agent" <> _} =
               Tool.call(
                 tool!(Present, "prompt_user"),
                 %{"$type" => "Button", "label" => "ok"},
                 ctx
               )
    end

    test "the instructions say when to draw instead of writing" do
      step = Present.call(Step.new(phase: :request), Present.init([]))
      text = Enum.join(step.instructions, "\n")
      assert text =~ "present"
      assert text =~ "prompt_user"
      assert Map.has_key?(step.tools, "present") and Map.has_key?(step.tools, "prompt_user")
    end
  end

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
      # a role's prompt is read again at every step, so an edit reaches a running agent too
      assert text =~ "re-read at every step"

      # and a task cannot override a role's rules — the parent is told to write tasks within them
      assert text =~ "cannot override"
    end

    test "two members with one name (a closed one's row revived by a restart) never break the tools' schema" do
      twins = [
        %{id: "a", name: "researcher", status: "done", role: "researcher", task: "x"},
        %{id: "b", name: "researcher", status: "done", role: "researcher", task: "y"}
      ]

      step = Agents.call(team_step(%{children: twins}), Agents.init([]))
      assert step.tools["close_agent"].schema["properties"]["agent"]["enum"] == ["researcher"]
      assert step.tools["send_message"].schema["properties"]["agent"]["enum"] == ["researcher"]
      assert :ok = Tool.validate(step.tools["close_agent"].schema, %{"agent" => "researcher"})
    end

    test "agents [...] narrows the choices; a role nobody declared is not offered" do
      step = Agents.call(team_step(%{allowed: ["reviewer", "ghost"]}), Agents.init([]))
      assert step.tools["spawn_agent"].schema["properties"]["agent"]["enum"] == ["reviewer"]
    end

    test "at the depth limit or with a full team nothing can be spawned, and the prompt says so" do
      deep = Agents.call(team_step(%{depth: 2}), Agents.init(max_depth: 2))
      refute Map.has_key?(deep.tools, "spawn_agent")
      assert Enum.join(deep.instructions, "\n") =~ "cannot spawn"

      kids =
        for i <- 1..4,
            do: %{
              id: "c#{i}",
              name: "researcher-#{i}",
              status: "working",
              role: "researcher",
              task: "t#{i}"
            }

      full = Agents.call(team_step(%{children: kids}), Agents.init(max_children: 4))
      refute Map.has_key?(full.tools, "spawn_agent")
      # the live children can still be spoken to and closed
      assert full.tools["send_message"].schema["properties"]["agent"]["enum"] ==
               Enum.map(kids, & &1.name)

      assert Map.has_key?(full.tools, "close_agent")
    end

    test "with nothing declared there is nothing to spawn, and the prompt says how to declare an agent" do
      step = Agents.call(team_step(%{agents: []}), Agents.init([]))
      refute Map.has_key?(step.tools, "spawn_agent")
      text = Enum.join(step.instructions, "\n")
      assert text =~ "No agent is declared yet"
      assert text =~ ".longx/local/agents/<name>/agent.exs"
      assert text =~ "prompt_file"
      # a child at the depth limit is not told to declare anyone
      assert Agents.call(team_step(%{agents: [], depth: 2}), Agents.init([])).instructions == []
    end

    test "the team persists: finished children and siblings can be messaged; only working ones count against the limit" do
      kids = [
        %{id: "c1", name: "researcher", status: "done", role: "researcher", task: "find X"},
        %{
          id: "c2",
          name: "reviewer",
          status: "working",
          role: "reviewer",
          task: "review the patch"
        }
      ]

      sibs = [%{id: "s1", name: "writer", role: "writer", task: "write the post"}]

      step =
        Agents.call(
          team_step(%{children: kids, siblings: sibs, name: "planner"}),
          Agents.init(max_children: 2)
        )

      # one of two is working: room for another
      assert Map.has_key?(step.tools, "spawn_agent")

      assert step.tools["send_message"].schema["properties"]["agent"]["enum"] ==
               ["researcher", "reviewer", "writer"]

      assert step.tools["send_message"].description =~ "keeps"

      assert step.tools["close_agent"].schema["properties"]["agent"]["enum"] == [
               "researcher",
               "reviewer"
             ]

      text = Enum.join(step.instructions, "\n")
      assert text =~ "researcher (researcher, done): find X"
      assert text =~ "reviewer (reviewer, working): review the patch"
      assert text =~ "writer (writer): write the post"
      assert text =~ "ask it again"
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

      # the continuation says where it comes from, so the page draws a marker, not a bubble in the person's voice
      assert [{:continue, text, %{"kind" => "goal", "round" => 1, "objective" => "ship it"}}] =
               step.effects

      assert text =~ "ship it"
      assert text =~ "update_goal"
      assert step.state.goal_rounds == 1

      assert Goal.call(goal_step(%{active | "status" => "complete"}), Goal.init([])).effects == []
      assert Goal.call(goal_step(%{active | "status" => "paused"}), Goal.init([])).effects == []
      assert Goal.call(goal_step(nil), Goal.init([])).effects == []
    end

    test "while a child works the goal waits for its report instead of spending rounds (a parent waiting on coder was continued eight times and blocked)" do
      active = %{"objective" => "ship it", "status" => "active"}

      working =
        Step.new(
          phase: :turn_end,
          assigns: %{
            goal: active,
            children: [%{id: "c", name: "coder", status: "working", role: nil, task: "run it"}]
          },
          state: %{goal_rounds: 2}
        )

      assert Goal.call(working, Goal.init([])).effects == []

      done =
        Step.new(
          phase: :turn_end,
          assigns: %{
            goal: active,
            children: [%{id: "c", name: "coder", status: "done", role: nil, task: "run it"}]
          },
          state: %{}
        )

      assert [{:continue, _, _}] = Goal.call(done, Goal.init([])).effects
    end

    test "too many rounds in one turn, or the budget spent, block the goal instead of looping" do
      active = %{"objective" => "ship it", "status" => "active"}
      # the goal says why it is blocked: the bar shows the reason, not a bare 卡住了
      step = Goal.call(goal_step(active, %{goal_rounds: 8}), Goal.init(max_rounds: 8))
      assert [{:goal, %{"status" => "blocked", "reason" => "rounds"}}] = step.effects

      spent = Map.merge(active, %{"tokenBudget" => 100, "tokensUsed" => 120})
      step = Goal.call(goal_step(spent), Goal.init([]))
      assert [{:goal, %{"status" => "blocked", "reason" => "budget"}}] = step.effects
    end

    test "the tools: create, update, get; update_goal takes the model's reason for a block" do
      names = Enum.map(Goal.__agent_tools__(), & &1.name) |> Enum.sort()
      assert names == ["create_goal", "get_goal", "update_goal"]
      update = Enum.find(Goal.__agent_tools__(), &(&1.name == "update_goal"))
      assert "reason" in Map.keys(update.schema["properties"])
    end
  end

  describe "Local" do
    alias Longx.Agent.Plugs.Local

    test "a trusted project's agent is told the two files of a custom tool and where the reference is",
         %{dir: dir} do
      step = Local.call(Step.new(phase: :request, cwd: dir), Local.init(root: dir))
      text = Enum.join(step.instructions, "\n")
      assert text =~ "local/plugs/<name>.exs"
      assert text =~ "local/agent.exs"
      assert text =~ "next step"
      # the reference rides along: the plug API, the outcome shapes, when to write one
      assert text =~ "use Longx.Agent.Plug"
      assert text =~ "{:ok, text, meta}"
      assert text =~ "When to write one"
      assert text =~ "prompt_file"

      # what Longx ships wins over what the agent wrote earlier: a stale local doc or tool is fixed, not followed
      assert text =~ "precedence"
      refute text =~ "not trusted"

      untrusted =
        Local.call(Step.new(phase: :request, cwd: dir), Local.init(root: dir, trusted: false))

      assert Enum.join(untrusted.instructions, "\n") =~ "not trusted"
    end

    test "the models the agent may name in a description, with their levels and the default", %{
      dir: dir
    } do
      choices = [
        %{
          slug: "ultra",
          name: "旗舰",
          provider: "",
          levels: [],
          default_level: nil,
          default?: false,
          alias: ["qwen3.8-max", "deepseek-flash"]
        },
        %{
          slug: "pro",
          name: "高级",
          provider: "",
          levels: [],
          default_level: nil,
          default?: false,
          alias: ["deepseek-flash"]
        },
        %{
          slug: "deepseek-flash",
          name: "DeepSeek Flash",
          provider: "DeepSeek",
          levels: ["none", "low", "high"],
          default_level: "high",
          default?: true
        },
        %{
          slug: "qwen3.8-max",
          name: "Qwen 3.8 Max",
          provider: "阿里云百炼",
          levels: [],
          default_level: nil,
          default?: false
        }
      ]

      step =
        Local.call(
          Step.new(phase: :request, cwd: dir, assigns: %{models: choices}),
          Local.init(root: dir)
        )

      text = Enum.join(step.instructions, "\n")
      assert text =~ "# Models"
      # tiers and aliases first, with their chain; a description should prefer them
      assert text =~ "`ultra` (旗舰) → qwen3.8-max, then deepseek-flash"
      assert text =~ "`pro` (高级) → deepseek-flash"
      assert text =~ "Prefer a tier or alias"

      assert text =~
               "`deepseek-flash` — DeepSeek Flash (DeepSeek); levels none, low, high; default level high; the default model"

      assert text =~ "`qwen3.8-max` — Qwen 3.8 Max (阿里云百炼)"
      assert text =~ "model \"<name>\""

      none = Local.call(Step.new(phase: :request, cwd: dir), Local.init(root: dir))
      refute Enum.join(none.instructions, "\n") =~ "# Models"
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
    test "output that is not UTF-8 is scrubbed, streamed and stored: the view stays JSON-encodable; a clip never cuts a character",
         %{dir: dir} do
      me = self()
      ctx = %Context{cwd: dir, emit: &send(me, {:emitted, &1})}
      tool = tool!(Shell, "exec_command")

      assert {:ok, output, _} = Tool.call(tool, %{"cmd" => ~S|printf 'a\377\376b'|}, ctx)
      assert String.valid?(output)
      assert output =~ "a"
      assert output =~ "b"
      assert_receive {:emitted, chunk}
      assert String.valid?(chunk)

      # a long multibyte output clipped in the middle: both halves valid
      assert {:ok, clipped, _} =
               Tool.call(
                 tool,
                 %{"cmd" => "yes 中文 | head -c 40000", "max_output_tokens" => 200},
                 ctx
               )

      assert String.valid?(clipped)
      assert clipped =~ "bytes omitted"
    end

    test "runs the command in the cwd and streams its output", %{dir: dir} do
      me = self()
      ctx = %Context{cwd: dir, emit: &send(me, {:emitted, &1})}
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
      assert path == Longx.Agent.Tools.ShellEnv.env()["PATH"]
      assert home == System.get_env("HOME")
    end

    test "the guards from the options: the tree's oom_score_adj, an address-space cap, and the prompt saying so",
         %{ctx: ctx} do
      step =
        Shell.call(
          Step.new(phase: :request),
          Shell.init(oom_score_adj: 700, memory_percent: 50, memory_floor_percent: 8)
        )

      tool = step.tools["exec_command"]
      assert tool.description =~ "address space"
      assert tool.description =~ "8%"

      # the command's own oom_score_adj is the setting's
      assert {:ok, out, _} =
               Tool.call(tool, %{"cmd" => "cat /proc/self/oom_score_adj", "login" => false}, ctx)

      assert String.trim(out) =~ "700"

      # an allocation past the cap fails inside the command, not in the BEAM (a tiny cap for the test)
      tiny = Shell.call(Step.new(phase: :request), Shell.init(memory_limit: 256 * 1024 * 1024))
      cmd = "python3 -c \"b = bytearray(512*1024*1024); print('allocated')\""

      assert {:ok, out, %{"exitCode" => code}} =
               Tool.call(tiny.tools["exec_command"], %{"cmd" => cmd, "login" => false}, ctx)

      assert out =~ "MemoryError"
      refute code == 0

      # no guards: the plain tool, no note
      plain = Shell.call(Step.new(phase: :request), Shell.init([]))
      refute plain.tools["exec_command"].description =~ "address space"
    end

    test "options Shell, timeout_ms: is the default timeout of every command (a role set 30 min and got 2)",
         %{ctx: ctx} do
      step = Shell.call(Step.new(phase: :request), Shell.init(timeout_ms: 500))
      tool = step.tools["exec_command"]
      assert tool.description =~ "default 500"

      assert {:error, message} =
               Tool.call(tool, %{"cmd" => "echo start; sleep 10", "login" => false}, ctx)

      assert message =~ "timed out after 500 ms"
      # a call's own timeout_ms still wins, within the cap
      assert {:ok, _, _} =
               Tool.call(
                 tool,
                 %{"cmd" => "sleep 0.8; echo done", "login" => false, "timeout_ms" => 5_000},
                 ctx
               )
    end

    test "memory pressure kills the command and the model is told why", %{ctx: ctx} do
      step = Shell.call(Step.new(phase: :request), Shell.init(memory_floor_percent: 10))
      tool = step.tools["exec_command"]
      me = self()
      ctx = %{ctx | emit: &send(me, {:emitted, &1})}

      task =
        Task.async(fn ->
          Tool.call(
            tool,
            %{"cmd" => "echo start; sleep 20", "login" => false, "timeout_ms" => 15_000},
            ctx
          )
        end)

      # the command registered itself (with its floor) before it started; a sweep below the floor kills it
      assert_receive {:emitted, "start\n"}, 5_000
      task_pid = task.pid

      assert [{^task_pid, %{floor: 10}}] =
               Enum.filter(Longx.System.Pressure.running(), &(elem(&1, 0) == task_pid))

      assert Longx.System.Pressure.sweep(%{total: 100, available: 3}) == 1

      assert {:error, message} = Task.await(task, 10_000)
      assert message =~ "killed by Longx"
      assert message =~ "3%"
      assert message =~ "start"
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

    test "a patch that arrived mangled is straightened before parsing: under another key, newlines as literal \\n, inside a code fence",
         %{dir: dir, ctx: ctx} do
      File.write!(Path.join(dir, "a.txt"), "one\ntwo\n")
      tool = tool!(Patch, "apply_patch")
      patch = "*** Begin Patch\n*** Update File: a.txt\n@@\n-two\n+2\n*** End Patch\n"

      # the whole patch under `patch` instead of `input`
      assert %{"input" => ^patch} = Patch.normalize(%{"patch" => patch})
      # newlines escaped once too often (no real newline in the text)
      assert %{"input" => ^patch} =
               Patch.normalize(%{"input" => String.replace(patch, "\n", "\\n")})

      # a markdown fence around it
      assert %{"input" => "*** Begin Patch\n" <> _ = inner} =
               Patch.normalize(%{"input" => "```patch\n" <> patch <> "```\n"})

      assert String.trim(inner) == String.trim(patch)
      # a proper one is untouched, and a real newline inside means no unescaping
      assert Patch.normalize(%{"input" => patch}) == %{"input" => patch}
      literal = "*** Begin Patch\n*** Add File: c.txt\n+a\\nb\n*** End Patch\n"
      assert Patch.normalize(%{"input" => literal}) == %{"input" => literal}

      assert {:ok, "Done!" <> _, _} =
               Tool.call(tool, %{"patch" => String.replace(patch, "\n", "\\n")}, ctx)

      assert File.read!(Path.join(dir, "a.txt")) == "one\n2\n"
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
