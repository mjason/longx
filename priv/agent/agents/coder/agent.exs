# A starter role shipped with Longx: does a bounded piece of coding work.
import Longx.Agent.Config

agent do
  version 1
  summary "implements a bounded, well-specified task in the code base and reports what changed"
  prompt_file "prompt.md"
  agents ["researcher", "reviewer"]
end
