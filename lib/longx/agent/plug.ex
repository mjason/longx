defmodule Longx.Agent.Plug do
  @moduledoc """
  The one extension point of the agent kernel — the plug pattern over a
  `Longx.Agent.Step` instead of a `Plug.Conn`: `init/1` prepares the
  options once, `call/2` transforms the step. What a plug contributes is
  data on the step: instructions, skills and tools.

  `use Longx.Agent.Plug` gives a declarative surface for the common case:

      defmodule MyPlugs.Shell do
        use Longx.Agent.Plug

        instructions "Run commands with exec."

        tool :exec, "Runs a shell command", show: :command, timeout: 600_000 do
          param :command, :string, "the command line", required: true
          param :timeout_ms, :integer, "kill after this many ms"
        end

        def exec(%{"command" => command}, ctx), do: {:ok, "..."}
      end

  Every `tool` becomes a `Longx.Agent.Tool` whose function is the module
  function of the same name (arity 2: decoded arguments, a
  `Longx.Agent.Context`). The default `call/2` mounts the declared
  instructions and tools; override it to compute them (and call `mount/2`
  for the declared ones). `init/1` defaults to the options themselves.
  """

  alias Longx.Agent.Step

  @callback init(keyword) :: term
  @callback call(Step.t(), term) :: Step.t()

  defmacro __using__(_opts) do
    quote do
      @behaviour Longx.Agent.Plug
      import Longx.Agent.Plug, only: [tool: 3, tool: 4, param: 3, param: 4, instructions: 1]
      alias Longx.Agent.{Context, Step, Tool}

      Module.register_attribute(__MODULE__, :agent_tools, accumulate: true)
      Module.register_attribute(__MODULE__, :agent_instructions, accumulate: true)
      Module.register_attribute(__MODULE__, :agent_params, [])
      @before_compile Longx.Agent.Plug

      @impl Longx.Agent.Plug
      def init(opts), do: opts

      @impl Longx.Agent.Plug
      def call(step, _opts), do: Longx.Agent.Plug.mount(step, __MODULE__)

      defoverridable init: 1, call: 2
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      @doc false
      def __agent_tools__, do: Enum.reverse(@agent_tools)
      @doc false
      def __agent_instructions__, do: Enum.reverse(@agent_instructions)
    end
  end

  @doc "A piece of prompt text the plug contributes (several allowed, in order)."
  defmacro instructions(text) do
    quote do
      @agent_instructions unquote(text)
    end
  end

  @doc """
  Declares a tool. Options: `show:` (`:command` | `:file_change` | `:tool`),
  `timeout:` (ms), `namespace:` (defaults to the module's last segment).
  The `do` block lists the parameters with `param`.
  """
  defmacro tool(name, description, opts \\ [], do: block) do
    quote do
      Module.put_attribute(__MODULE__, :agent_params, [])
      unquote(block)

      @agent_tools Longx.Agent.Tool.declare(
                     __MODULE__,
                     unquote(name),
                     unquote(description),
                     Enum.reverse(Module.get_attribute(__MODULE__, :agent_params)),
                     unquote(opts)
                   )
    end
  end

  @doc "One parameter of the enclosing `tool`: name, type, description and `required: true`."
  defmacro param(name, type, doc, opts \\ []) do
    quote do
      Module.put_attribute(
        __MODULE__,
        :agent_params,
        [
          {unquote(name), unquote(type), unquote(doc), unquote(opts)}
          | Module.get_attribute(__MODULE__, :agent_params)
        ]
      )
    end
  end

  @doc "Puts the module's declared instructions and tools on the step."
  @spec mount(Step.t(), module) :: Step.t()
  def mount(%Step{} = step, module) do
    step
    |> Step.instructions(module.__agent_instructions__())
    |> Step.tools(module.__agent_tools__())
  end
end
