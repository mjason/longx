defmodule Longx.Codex.Tool do
  @moduledoc """
  A tool the agent can call, implemented in Elixir.

  Codex learns about these as *dynamic tools* (`thread/start.dynamicTools`)
  and calls them through the `item/tool/call` server → client request; the
  `Longx.Codex.Tool.Runner` validates the arguments against `input_schema/0`,
  runs `call/2` under a timeout, and turns the result into codex's
  `DynamicToolCallResponse`.

  ## Adding a tool

  One module, one file, anywhere in this application (convention:
  `lib/longx/tools/<namespace>/<name>.ex`). Implement this behaviour and the
  `Longx.Codex.Tool.Registry` picks it up at boot — no central list to edit.
  Built-in tools use the `builtin` namespace; a fork adds its own namespace.

      defmodule Longx.Tools.Acme.Weather do
        @behaviour Longx.Codex.Tool

        @impl true
        def name, do: "weather"
        @impl true
        def namespace, do: "acme"
        @impl true
        def description, do: "Current weather for a city. Use when the user asks about weather."
        @impl true
        def input_schema do
          %{"type" => "object", "properties" => %{"city" => %{"type" => "string"}},
            "required" => ["city"], "additionalProperties" => false}
        end
        @impl true
        def call(%{"city" => city}, %Longx.Codex.Tool.Context{} = _ctx) do
          {:ok, "It is sunny in " <> city}
        end
      end

  `description/0` is what the model reads to decide when to call the tool;
  write it for the model. Arguments arrive validated against `input_schema/0`
  (string keys), so pattern matching in `call/2` is safe. Return `{:ok, text}`,
  `{:ok, [content]}` for mixed text/images, or `{:error, message}` — the
  message goes back to the model as a failed tool call, never as a crash.
  """

  alias Longx.Codex.Tool.Context

  @type content :: {:text, String.t()} | {:image_url, String.t()}
  @type result :: {:ok, String.t() | [content]} | {:error, String.t()}

  @doc "Tool name as the model sees it, e.g. `\"thread_status\"`."
  @callback name() :: String.t()

  @doc "Groups tools; `builtin` for ours. Defaults to `\"builtin\"`."
  @callback namespace() :: String.t()

  @doc "Explains to the model what the tool does and when to use it."
  @callback description() :: String.t()

  @doc "JSON Schema (draft 7, string keys) for the arguments."
  @callback input_schema() :: map

  @doc "Whether to offer this tool on a given thread. Defaults to `true`."
  @callback available?(Context.t()) :: boolean

  @doc "Max runtime in milliseconds. Defaults to 30 000."
  @callback timeout() :: pos_integer

  @callback call(arguments :: map, Context.t()) :: result

  @doc """
  Whether the tool's switch (`Longx.AI.Tool`) starts on when it is first
  seen. Defaults to `false`: a new tool is registered, not injected, until
  someone turns it on. A person's choice is never overridden by this.
  """
  @callback enabled_by_default?() :: boolean

  @optional_callbacks namespace: 0, available?: 1, timeout: 0, enabled_by_default?: 0

  @default_namespace "builtin"
  @default_timeout 30_000

  @doc false
  def default_namespace, do: @default_namespace
  @doc false
  def default_timeout, do: @default_timeout
end
