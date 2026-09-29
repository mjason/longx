// The status strip's word on what runs now, any project: `3 个在跑 · 1 个等你`,
// amber when someone waits on the person, a breathing blue dot otherwise;
// a click opens the running-conversations picker (the same as SPC t r).
// Nothing while nothing runs.
import { useMatch, useNavigate } from "react-router";
import { useRunningThreads } from "@/core/projects";
import { openRunningPicker } from "@/ui/keys/runningPicker";
import { t } from "@/ui/strings";

export function RunningChip({ className = "" }: { className?: string }) {
  const navigate = useNavigate();
  const threadId = useMatch("/p/:slug/t/:threadId")?.params.threadId ?? null;
  const running = useRunningThreads();
  const threads = running.data ?? [];
  if (threads.length === 0) return null;
  const waiting = threads.filter((r) => r.waiting).length;
  return (
    <button
      type="button"
      className={`${className} ${waiting > 0 ? "text-warning" : "text-primary"} cursor-pointer hover:underline`}
      title={t.keys.runningThreads}
      data-testid="running-chip"
      onClick={() => openRunningPicker(threads, threadId, navigate)}
    >
      <span className={`size-2 shrink-0 rounded-full ${waiting > 0 ? "bg-warning" : "bg-primary animate-pulse"}`} aria-hidden="true" />
      {t.runningStrip(threads.length, waiting)}
    </button>
  );
}
