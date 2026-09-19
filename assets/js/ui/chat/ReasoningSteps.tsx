// The model's thinking as the reasoning element's step-panel design: titled
// steps down a timeline, a shimmering "思考中" while it streams that settles
// into a resting label. The steps come from the group's reasoning parts
// (core/chat/reasoningSteps); closed until the reader opens it — a page
// that unfolded every thought while it streamed was too long to follow —
// and their choice sticks.
import { useAuiState } from "@assistant-ui/react";
import type { ThreadGroupPart } from "@/ui/components/assistant-ui/elements/thread.aui";
import { useMemo, useState } from "react";
import { reasoningSteps } from "@/core/chat/reasoningSteps";
import { ReasoningPanel } from "@/ui/components/assistant-ui/elements/reasoning-panel";
import { t } from "@/ui/strings";

export function ReasoningSteps({ group }: { group: ThreadGroupPart }) {
  const parts = useAuiState((s) => s.message.parts);
  const steps = useMemo(
    () =>
      group.indices.flatMap((i) => {
        const part = parts[i];
        return part?.type === "reasoning" ? reasoningSteps(part.text) : [];
      }),
    [parts, group.indices],
  );
  const streaming = group.status.type === "running";
  const [userOpen, setUserOpen] = useState<boolean | null>(null);
  if (steps.length === 0) return null;
  return (
    <ReasoningPanel
      steps={steps}
      visibleSteps={steps.length}
      streaming={streaming}
      open={userOpen ?? false}
      onOpenChange={setUserOpen}
      restingLabel={t.reasoningDone}
      className="mb-1 max-w-none"
    />
  );
}
