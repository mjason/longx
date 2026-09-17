defmodule Longx.Agent.PlugsTest do
  use ExUnit.Case, async: true

  alias Longx.Agent.{Context, Step, Tool}
  alias Longx.Agent.Plugs.{AgentsMd, Base, Environment, Files, Request, Shell}

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

  describe "Shell.exec" do
    test "runs the command in the cwd and streams its output", %{dir: dir} do
      me = self()
      ctx = %Context{cwd: dir, emit: &send(me, {:out, &1})}
      tool = tool!(Shell, "exec")

      assert tool.show == :command

      assert {:ok, output, %{"exitCode" => 0}} =
               Tool.call(tool, %{"command" => "pwd; echo hi >&2"}, ctx)

      assert output =~ dir
      assert output =~ "hi"
      # every chunk was emitted before the call returned
      assert Enum.join(collect_out([])) =~ dir
    end

    test "a non-zero exit is reported, not an error", %{ctx: ctx} do
      assert {:ok, output, %{"exitCode" => 3}} =
               Tool.call(tool!(Shell, "exec"), %{"command" => "echo boom; exit 3"}, ctx)

      assert output =~ "boom"
      assert output =~ "exit code 3"
    end

    test "a command past its timeout is killed", %{ctx: ctx} do
      assert {:error, message} =
               Tool.call(
                 tool!(Shell, "exec"),
                 %{"command" => "echo start; sleep 10", "timeout_ms" => 300},
                 ctx
               )

      assert message =~ "timed out"
      assert message =~ "start"
    end
  end

  describe "Files" do
    test "read, write and edit", %{dir: dir, ctx: ctx} do
      write = tool!(Files, "write_file")
      assert write.show == :file_change

      assert {:ok, _, %{"changes" => [%{"path" => path, "kind" => "add"}]}} =
               Tool.call(write, %{"path" => "a/b.txt", "content" => "one\ntwo\n"}, ctx)

      assert path == Path.join(dir, "a/b.txt")
      assert File.read!(path) == "one\ntwo\n"

      assert {:ok, "one\ntwo\n"} =
               Tool.call(tool!(Files, "read_file"), %{"path" => "a/b.txt"}, ctx)

      assert {:ok, "two\n"} =
               Tool.call(
                 tool!(Files, "read_file"),
                 %{"path" => "a/b.txt", "offset" => 2, "limit" => 1},
                 ctx
               )

      assert {:ok, _, %{"changes" => [%{"kind" => "update"}]}} =
               Tool.call(
                 tool!(Files, "edit_file"),
                 %{"path" => "a/b.txt", "old_string" => "two", "new_string" => "2"},
                 ctx
               )

      assert File.read!(path) == "one\n2\n"
    end

    test "an edit must match exactly once", %{dir: dir, ctx: ctx} do
      File.write!(Path.join(dir, "x.txt"), "a a\n")
      edit = tool!(Files, "edit_file")

      assert {:error, msg} =
               Tool.call(
                 edit,
                 %{"path" => "x.txt", "old_string" => "a", "new_string" => "b"},
                 ctx
               )

      assert msg =~ "2 times"

      assert {:error, msg} =
               Tool.call(
                 edit,
                 %{"path" => "x.txt", "old_string" => "z", "new_string" => "b"},
                 ctx
               )

      assert msg =~ "not found"

      assert {:ok, _, _} =
               Tool.call(
                 edit,
                 %{
                   "path" => "x.txt",
                   "old_string" => "a",
                   "new_string" => "b",
                   "replace_all" => true
                 },
                 ctx
               )

      assert File.read!(Path.join(dir, "x.txt")) == "b b\n"
    end

    test "reading a missing file is an error the model can act on", %{ctx: ctx} do
      assert {:error, msg} = Tool.call(tool!(Files, "read_file"), %{"path" => "nope.txt"}, ctx)
      assert msg =~ "nope.txt"
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
