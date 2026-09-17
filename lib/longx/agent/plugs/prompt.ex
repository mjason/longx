defmodule Longx.Agent.Plugs.Prompt do
  @moduledoc """
  A piece of prompt text from a description (`prompt` in `agent.exs`) or
  a loader notice.
  """

  use Longx.Agent.Plug

  @impl true
  def init(opts), do: Keyword.fetch!(opts, :text)

  @impl true
  def call(%Step{phase: :request} = step, text), do: Step.instructions(step, text)
  def call(step, _text), do: step
end
