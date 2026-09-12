defmodule Longx.Test.Tools.Boom do
  @moduledoc "Test tool that raises."
  @behaviour Longx.Codex.Tool

  @impl true
  def name, do: "boom"
  @impl true
  def namespace, do: "test"
  @impl true
  def description, do: "Always crashes."
  @impl true
  def input_schema, do: %{"type" => "object"}
  @impl true
  def call(_args, _ctx), do: raise("kaboom")
end

defmodule Longx.Test.Tools.Slow do
  @moduledoc "Test tool that sleeps longer than its timeout."
  @behaviour Longx.Codex.Tool

  @impl true
  def name, do: "slow"
  @impl true
  def namespace, do: "test"
  @impl true
  def description, do: "Takes forever."
  @impl true
  def input_schema, do: %{"type" => "object"}
  @impl true
  def timeout, do: 200
  @impl true
  def call(_args, _ctx) do
    Process.sleep(5_000)
    {:ok, "never"}
  end
end

defmodule Longx.Test.Tools.Failing do
  @moduledoc "Test tool that returns an error, and an image."
  @behaviour Longx.Codex.Tool

  @impl true
  def name, do: "failing"
  @impl true
  def namespace, do: "test"
  @impl true
  def description, do: "Returns an error unless asked for a picture."
  @impl true
  def input_schema,
    do: %{"type" => "object", "properties" => %{"picture" => %{"type" => "boolean"}}}

  @impl true
  def call(%{"picture" => true}, _ctx),
    do: {:ok, [{:text, "here"}, {:image_url, "https://x/y.png"}]}

  def call(_args, _ctx), do: {:error, "nope"}
end

defmodule Longx.Test.Tools.Contextual do
  @moduledoc "Test tool that reports what it was given in its context, and is only available when the cwd is set."
  @behaviour Longx.Codex.Tool

  @impl true
  def name, do: "contextual"
  @impl true
  def namespace, do: "test"
  @impl true
  def description, do: "Reports its context."
  @impl true
  def input_schema, do: %{"type" => "object"}
  @impl true
  def available?(%Longx.Codex.Tool.Context{cwd: cwd}), do: is_binary(cwd)
  @impl true
  def call(_args, %Longx.Codex.Tool.Context{} = ctx) do
    {:ok,
     "thread=#{ctx.thread_id} turn=#{ctx.turn_id} call=#{ctx.call_id} cwd=#{ctx.cwd} items=#{length(ctx.snapshot.().items)}"}
  end
end
