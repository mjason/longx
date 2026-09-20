defmodule Longx.Agent.Plugs.Base do
  @moduledoc """
  The base prompt — `priv/agent/base_prompt.md`, read at compile time: codex's
  `instructions_template` for gpt-5.6 (`codex-rs/models-manager/models.json`,
  kept as `test/support/fixtures/codex_gpt56_instructions.md`) with only what
  differs here changed — the identity (Longx, no model named: DeepSeek and
  Qwen run here too), Harmony's `commentary` / `final` channels said in plain
  words, a file reference as a path rather than a link, no `$CODEX_HOME`, the
  skills section out (the knowledge plug speaks for itself), a "where you
  work" section and a line on commands running to completion added. The test
  in `plugs_test` lists every paragraph that differs; anything else drifting
  from codex's text fails it.
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
