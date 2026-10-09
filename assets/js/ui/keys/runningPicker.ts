// The running-conversations picker (`thread.running`: SPC t r, ⌥⇧↑, the status
// strip's chip): every conversation with a turn in flight, any project — the
// ones waiting on the person first, then by last activity as the server lists
// them —, each with its project, what it is doing (the ask, the sub-agents at
// work, what the model writes and for how long) and the one on screen marked;
// under them the ones that finished lately, how their turn ended and when —
// the way back to a task that ended while the person looked elsewhere. ⌘K
// lists them too, among everything else; ⌥⇧↓ walks only the waiting ones.
import { openPicker, type PickerItem } from "@/core/keys/picker";
import { formatElapsed, relativeTime } from "@/core/format";
import type { FinishedThread, RunningThread } from "@/core/projects";
import { progressLabel } from "@/ui/chat/progressLabel";
import { t } from "@/ui/strings";

const name = (r: { id: string; title: string | null; preview: string | null }) => r.title || r.preview || `~${r.id.slice(-6)}`;

function doing(r: RunningThread, nowMs: number): { hint: string; tone: "waiting" | "running" } {
  if (r.waiting) return { hint: t.keys.waiting, tone: "waiting" };
  if (r.jobActivity?.total) return { hint: `${t.jobWork.states[r.jobActivity.state]} · ${t.jobWork.count(r.jobActivity.total)}`, tone: "waiting" };
  if (r.working?.length) return { hint: t.agentsWorking(r.working), tone: "running" };
  const what = progressLabel(r.progress, t.keys.running);
  const since = r.turnStartedAt ? Math.max(0, Math.round(nowMs / 1000 - r.turnStartedAt)) : null;
  return { hint: since !== null && since >= 60 ? `${what} · ${formatElapsed(since)}` : what, tone: "running" };
}

function ended(r: FinishedThread, nowMs: number): string {
  const outcome = t.finishedOutcome[r.outcome] ?? r.outcome;
  return r.finishedAt ? `${outcome} · ${relativeTime(new Date(r.finishedAt * 1000).toISOString(), new Date(nowMs))}` : outcome;
}

/** The picker's rows: what runs now, then what finished lately. */
export function runningItems(threads: RunningThread[], finished: FinishedThread[], currentId: string | null, nowMs: number): PickerItem[] {
  const ordered = [...threads].sort((a, b) => Number(b.waiting) - Number(a.waiting));
  const running: PickerItem[] = ordered.map((r) => ({
    id: r.id,
    label: name(r),
    note: r.projectName,
    group: t.keys.groupRunning,
    ...doing(r, nowMs),
    ...(r.id === currentId ? { current: true } : {}),
    keywords: `${r.projectName} ${r.projectSlug} ${r.preview ?? ""}`,
  }));
  const done: PickerItem[] = finished.map((r) => ({
    id: r.id,
    label: name(r),
    note: r.projectName,
    group: t.keys.groupFinished,
    hint: ended(r, nowMs),
    tone: "finished",
    ...(r.id === currentId ? { current: true } : {}),
    keywords: `${r.projectName} ${r.projectSlug} ${r.preview ?? ""}`,
  }));
  return [...running, ...done];
}

/** Opens the picker over `threads` and `finished`; a pick goes to that conversation's page. */
export function openRunningPicker(threads: RunningThread[], finished: FinishedThread[], currentId: string | null, navigate: (to: string) => void): void {
  openPicker({
    title: t.keys.runningThreads,
    items: runningItems(threads, finished, currentId, Date.now()),
    onPick: (item) => {
      const picked = [...threads, ...finished].find((r) => r.id === item.id);
      if (picked) navigate(`/p/${picked.projectSlug}/t/${picked.id}`);
    },
  });
}
