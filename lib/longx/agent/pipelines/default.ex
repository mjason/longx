defmodule Longx.Agent.Pipelines.Default do
  @moduledoc """
  What every step of a native thread runs through unless a project says
  otherwise: the environment, the base prompt, the project's AGENTS.md
  files, the shell and file tools, then the request.
  """

  use Longx.Agent.Pipeline

  plug Longx.Agent.Plugs.Environment
  plug Longx.Agent.Plugs.Base
  plug Longx.Agent.Plugs.AgentsMd
  plug Longx.Agent.Plugs.Shell
  plug Longx.Agent.Plugs.Files
  plug Longx.Agent.Plugs.Request
end
