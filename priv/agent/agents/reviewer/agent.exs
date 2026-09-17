# A starter role shipped with Longx: a read-only review of work.
import Longx.Agent.Config

agent do
  version 1
  summary "reviews a diff, a branch or a plan and reports findings ranked by severity — changes nothing"
  prompt_file "prompt.md"
  drop Longx.Agent.Plugs.Patch
  agents []
end
