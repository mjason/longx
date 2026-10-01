import Longx.Agent.Config

agent do
  version 1
  extends :default
  drop Longx.Agent.Plugs.AgentsMd
  plug Longx.ProjectGuidance
end
