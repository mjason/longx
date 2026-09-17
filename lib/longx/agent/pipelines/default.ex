defmodule Longx.Agent.Pipelines.Default do
  @moduledoc """
  What every step of a native thread runs through unless a project says
  otherwise: the environment, the base prompt, then codex's tool set —
  `exec_command`, `apply_patch`, `view_image` — and the request.
  """

  use Longx.Agent.Pipeline

  plug Longx.Agent.Plugs.Environment
  plug Longx.Agent.Plugs.Base
  plug Longx.Agent.Plugs.Shell
  plug Longx.Agent.Plugs.Patch
  plug Longx.Agent.Plugs.ViewImage
  plug Longx.Agent.Plugs.Request
end
