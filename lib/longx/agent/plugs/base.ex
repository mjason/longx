defmodule Longx.Agent.Plugs.Base do
  @moduledoc """
  The base prompt — `priv/agent/base_prompt.md`, read at compile time:
  codex's own prompt (`priv/codex_prompt.md`, the pinned release's)
  trimmed to what applies here — no sandbox, approvals, plans or
  AGENTS.md; the tool names ours — so models tuned for codex read the
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
