// The running-conversations picker (`thread.running`: SPC t r, ⌥⇧↑, the status
// strip's chip): every conversation with a turn in flight, any project — the
// ones waiting on the person first, then by last activity as the server lists
// them —, each with its project, what it is doing (the ask, the sub-agents at
// work, what the model writes and for how long) and the one on screen marked.
// ⌘K lists them too, among everything else; ⌥⇧↓ walks only the waiting ones.
import { openPicker, type PickerItem } from "@/core/keys/picker";
import { formatElapsed } from "@/core/format";
import type { RunningThread } from "@/core/projects";
import { progressLabel } from "@/ui/chat/progressLabel";
import { t } from "@/ui/strings";

const name = (r: RunningThread) => r.title || r.preview || `~${r.id.slice(-6)}`;

function doing(r: RunningThread, nowMs: number): { hint: string; tone: "waiting" | "running" } {
  if (r.waiting) return { hint: t.keys.waiting, tone: "waiting" };
  if (r.working?.length) return { hint: t.agentsWorking(r.working), tone: "running" };
  const what = progressLabel(r.progress, t.keys.running);
  const since = r.turnStartedAt ? Math.max(0, Math.round(nowMs / 1000 - r.turnStartedAt)) : null;
  return { hint: since !== null && since >= 60 ? `${what} · ${formatElapsed(since)}` : what, tone: "running" };
}

/** The picker's rows for what runs now. */
export function runningItems(threads: RunningThread[], currentId: string | null, nowMs: number): PickerItem[] {
  const ordered = [...threads].sort((a, b) => Number(b.waiting) - Number(a.waiting));
  return ordered.map((r) => ({
    id: r.id,
    label: name(r),
    note: r.projectName,
    ...doing(r, nowMs),
    ...(r.id === currentId ? { current: true } : {}),
    keywords: `${r.projectName} ${r.projectSlug} ${r.preview ?? ""}`,
  }));
}

/** Opens the picker over `threads`; a pick goes to that conversation's page. */
export function openRunningPicker(threads: RunningThread[], currentId: string | null, navigate: (to: string) => void): void {
  openPicker({
    title: t.keys.runningThreads,
    items: runningItems(threads, currentId, Date.now()),
    onPick: (item) => {
      const picked = threads.find((r) => r.id === item.id);
      if (picked) navigate(`/p/${picked.projectSlug}/t/${picked.id}`);
    },
  });
}
