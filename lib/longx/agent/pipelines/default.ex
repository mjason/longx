defmodule Longx.Agent.Pipelines.Default do
  @moduledoc """
  The shipped agent description — the base every layer builds on
  (`Longx.Agent.Definition.Loader`): the environment, the base prompt, the project's
  AGENTS.md, codex's tool
  set (`exec_command`, `apply_patch`, `view_image`), the cards (`present`), the knowledge, the web,
  the team and the request. In
  the same format as a project's `.longx/agent.exs`, only compiled in.
  """

  import Longx.Agent.Config

  alias Longx.Agent.Config

  @doc "The description."
  @spec config() :: Config.t()
  def config do
    agent do
      version 1

      pipeline do
        plug Longx.Agent.Plugs.Environment
        plug Longx.Agent.Plugs.Base
        # the project's AGENTS.md, as codex reads it; `drop AgentsMd` turns it off
        plug Longx.Agent.Plugs.AgentsMd
        plug Longx.Agent.Plugs.Shell
        plug Longx.Agent.Plugs.Patch
        plug Longx.Agent.Plugs.ViewImage
        plug Longx.Agent.Plugs.Present
        plug Longx.Agent.Plugs.Knowledge
        plug Longx.Agent.Plugs.WebSearch
        plug Longx.Agent.Plugs.Browser
        plug Longx.Agent.Plugs.Credentials
        plug Longx.Agent.Plugs.Agents
        plug Longx.Agent.Plugs.Watches
        plug Longx.Agent.Plugs.Goal
        plug Longx.Agent.Plugs.Compaction
        plug Longx.Agent.Plugs.Request
      end
    end
  end

  @doc "The plugs, in order."
  @spec plugs() :: [{module, keyword}]
  def plugs, do: Config.resolve([], config())

  @doc "Runs a step through the shipped pipeline (tests; the kernel goes through the loader)."
  @spec run(Longx.Agent.Step.t()) :: Longx.Agent.Step.t()
  def run(step), do: Longx.Agent.Pipeline.run(step, plugs())
end
