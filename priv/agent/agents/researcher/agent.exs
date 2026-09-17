# A starter role shipped with Longx: research on the web, report back.
# A project refines it in .longx/shared/agents/researcher/ (or local/).
import Longx.Agent.Config

agent do
  version 1
  summary "searches the web and reads pages, then reports findings with sources — changes nothing"
  prompt_file "prompt.md"
  drop Longx.Agent.Plugs.Patch
  agents []
end
