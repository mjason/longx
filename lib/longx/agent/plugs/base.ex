defmodule Longx.Agent.Plugs.Base do
  @moduledoc """
  The base prompt — `priv/agent/base_prompt.md`, read at compile time:
  who the model is, how to work, what the built-in tools are for.
  """

  use Longx.Agent.Plug

  @path Path.join(:code.priv_dir(:longx), "agent/base_prompt.md")
  @external_resource @path
  @prompt File.read!(@path)

  @doc "The prompt text."
  @spec prompt() :: String.t()
  def prompt, do: @prompt

  @impl true
  def call(%Step{} = step, _opts), do: Step.instructions(step, @prompt)
end
