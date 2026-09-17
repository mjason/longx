defmodule Longx.Agent.Plugs.Base do
  @moduledoc """
  The base prompt — `priv/agent/base_prompt.md`, read at compile time:
  derived from codex's prompt (its 0.154 release) trimmed to what applies
  here — no sandbox, approvals, plans or AGENTS.md; the tool names ours;
  a "where you work" rule added — so models tuned for codex read the
  voice they know.
  """

  use Longx.Agent.Plug

  @path Path.join(:code.priv_dir(:longx), "agent/base_prompt.md")
  @external_resource @path
  @prompt File.read!(@path)

  @doc "The prompt text."
  @spec prompt() :: String.t()
  def prompt, do: @prompt

  @impl true
  def call(%Step{phase: :request} = step, _opts), do: Step.instructions(step, @prompt)
  def call(step, _opts), do: step
end
