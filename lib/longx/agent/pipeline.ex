defmodule Longx.Agent.Pipeline do
  @moduledoc """
  A list of plugs a `Longx.Agent.Step` runs through, in order, until one
  halts — the kernel's `Plug.Builder`:

      defmodule Longx.Agent.Pipelines.Default do
        use Longx.Agent.Pipeline

        plug Longx.Agent.Plugs.Environment
        plug Longx.Agent.Plugs.Shell, timeout: 600_000
        plug Longx.Agent.Plugs.Request
      end

  `plugs/0` is the declared list, `run/1` runs a step through it; `run/2`
  takes a list built at runtime (a project's own plugs appended).
  """

  alias Longx.Agent.Step

  defmacro __using__(_opts) do
    quote do
      import Longx.Agent.Pipeline, only: [plug: 1, plug: 2]
      Module.register_attribute(__MODULE__, :agent_plugs, accumulate: true)
      @before_compile Longx.Agent.Pipeline
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      @doc "The plugs, in order, with their options."
      @spec plugs() :: [{module, keyword}]
      def plugs, do: Enum.reverse(@agent_plugs)

      @doc "Runs a step through the pipeline."
      @spec run(Longx.Agent.Step.t()) :: Longx.Agent.Step.t()
      def run(%Longx.Agent.Step{} = step), do: Longx.Agent.Pipeline.run(step, plugs())
    end
  end

  defmacro plug(module, opts \\ []) do
    quote do
      @agent_plugs {unquote(module), unquote(opts)}
    end
  end

  @doc "Runs `step` through `plugs` (`{module, opts}` pairs); a halted step stops the run."
  @spec run(Step.t(), [{module, keyword} | module]) :: Step.t()
  def run(%Step{} = step, plugs) when is_list(plugs) do
    Enum.reduce_while(plugs, step, fn plug, acc ->
      {module, opts} = normalize(plug)

      case module.call(acc, module.init(opts)) do
        %Step{halted: true} = halted -> {:halt, halted}
        %Step{} = next -> {:cont, next}
      end
    end)
  end

  defp normalize({module, opts}) when is_atom(module), do: {module, opts}
  defp normalize(module) when is_atom(module), do: {module, []}
end
