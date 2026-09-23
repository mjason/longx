// What a turn is doing right now, in words — the turn bar, a sub-agent's row and
// the Agents panel all say it the same way. A progress carrying `quiet` is an
// upstream that has sent nothing for that many seconds: said beside what it was
// doing, so a stuck provider does not read as Longx hanging.
import type { TurnProgress } from "@/core/chat/thread";
import { formatBytes } from "@/core/format";
import { t } from "@/ui/strings";

export function progressLabel(progress: TurnProgress | null | undefined, fallback: string): string {
  const doing =
    progress?.kind === "retry"
      ? t.turnRetrying(progress.name)
      : progress?.kind === "toolCall"
        ? t.turnWriting(progress.name, formatBytes(progress.bytes))
        : progress?.kind === "compaction"
          ? t.turnCompacting(progress.bytes ? formatBytes(progress.bytes) : null)
          : progress?.kind === "waiting"
            ? t.turnWaitingOn(progress.name)
            : fallback;
  return progress?.quiet != null ? `${doing} · ${t.upstreamQuiet(progress.quiet)}` : doing;
}
