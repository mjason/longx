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
