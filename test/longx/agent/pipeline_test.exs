defmodule Longx.Agent.PipelineTest do
  use ExUnit.Case, async: true

  alias Longx.Agent.{Pipeline, Step, Tool}

  defmodule Greeter do
    use Longx.Agent.Plug

    instructions "Be brief."

    tool :greet, "Says hello", show: :tool, timeout: 1_000 do
      param :name, :string, "who to greet", required: true
      param :times, :integer, "how many times"
      param :style, {:enum, ["plain", "loud"]}, "how"
      param :tags, {:array, :string}, "labels"
    end

    def greet(%{"name" => name}, _ctx), do: {:ok, "hello #{name}"}
  end

  defmodule Halter do
    use Longx.Agent.Plug

    def init(opts), do: Keyword.fetch!(opts, :reason)
    def call(step, reason), do: Step.halt(step, reason)
  end

  defmodule Tagger do
    use Longx.Agent.Plug

    def call(step, opts) do
      step
      |> Step.assign(:tag, Keyword.get(opts, :tag, "none"))
      |> Step.skill("deploy", "ships the branch", body: "run make deploy")
    end
  end

  defmodule MyPipeline do
    use Longx.Agent.Pipeline

    plug Greeter
    plug Tagger, tag: "t1"
  end

  defmodule HaltingPipeline do
    use Longx.Agent.Pipeline

    plug Halter, reason: :budget
    plug Tagger, tag: "never"
  end

  test "a plug declares tools with a JSON schema and its instructions" do
    [tool] = Greeter.__agent_tools__()

    assert %Tool{name: "greet", description: "Says hello", show: :tool, timeout: 1_000} = tool
    assert tool.namespace == "greeter"

    assert tool.schema == %{
             "type" => "object",
             "properties" => %{
               "name" => %{"type" => "string", "description" => "who to greet"},
               "times" => %{"type" => "integer", "description" => "how many times"},
               "style" => %{
                 "type" => "string",
                 "enum" => ["plain", "loud"],
                 "description" => "how"
               },
               "tags" => %{
                 "type" => "array",
                 "items" => %{"type" => "string"},
                 "description" => "labels"
               }
             },
             "required" => ["name"],
             "additionalProperties" => false
           }

    assert Tool.call(tool, %{"name" => "MJ"}, %{}) == {:ok, "hello MJ"}
    assert Greeter.__agent_instructions__() == ["Be brief."]
  end

  test "the default call mounts the tools and instructions on the step" do
    step = Greeter.call(Step.new(thread_id: "t1"), Greeter.init([]))

    assert Map.keys(step.tools) == ["greet"]
    assert step.instructions == ["Be brief."]
  end

  test "a pipeline runs its plugs in order with their options" do
    assert MyPipeline.plugs() == [{Greeter, []}, {Tagger, [tag: "t1"]}]

    step = MyPipeline.run(Step.new(thread_id: "t1"))

    assert step.assigns.tag == "t1"
    assert Map.keys(step.tools) == ["greet"]

    assert %{"deploy" => %{description: "ships the branch", body: "run make deploy"}} =
             step.skills

    refute step.halted
  end

  test "a halt stops the pipeline" do
    step = HaltingPipeline.run(Step.new(thread_id: "t1"))

    assert step.halted
    assert step.reason == :budget
    refute Map.has_key?(step.assigns, :tag)
  end

  test "run/2 takes a plug list at runtime" do
    step = Pipeline.run(Step.new(thread_id: "t1"), [{Tagger, [tag: "rt"]}])
    assert step.assigns.tag == "rt"
  end

  defmodule Phased do
    use Longx.Agent.Plug

    tool :noop, "nothing" do
      param :x, :string, "x"
    end

    def noop(_args, _ctx), do: {:ok, ""}

    def call(%Step{phase: :response} = step, _opts) do
      if step.calls == [],
        do: Step.enqueue_call(step, "exec_command", %{"cmd" => "mix test"}),
        else: step
    end

    def call(%Step{phase: :turn_end} = step, _opts), do: Step.continue(step, "keep going")
    def call(step, _opts), do: Longx.Agent.Plug.mount(step, __MODULE__)
  end

  test "a plug sees the phase: tools mount at request, effects describe what the kernel does next" do
    request = Phased.call(Step.new(phase: :request), [])
    assert Map.keys(request.tools) == ["noop"]
    assert request.effects == []

    response = Phased.call(Step.new(phase: :response, calls: []), [])
    assert response.tools == %{}
    assert response.effects == [{:call, "exec_command", %{"cmd" => "mix test"}}]

    busy = Phased.call(Step.new(phase: :response, calls: [%{name: "x"}]), [])
    assert busy.effects == []

    turn_end = Phased.call(Step.new(phase: :turn_end), [])
    assert turn_end.effects == [{:continue, "keep going"}]

    assert Step.compact(Step.new(), keep: 3).effects == [{:compact, [keep: 3]}]
  end

  test "the default call mounts nothing outside the request phase" do
    assert Greeter.call(Step.new(phase: :response), []).tools == %{}
    assert Greeter.call(Step.new(phase: :turn_end), []).instructions == []
  end

  test "a tool's schema refuses arguments it does not declare" do
    [tool] = Greeter.__agent_tools__()

    assert {:error, message} = Tool.call(tool, %{"nme" => "x"}, %{})
    assert message =~ "name"
  end
end
