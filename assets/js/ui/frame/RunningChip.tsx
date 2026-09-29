// The status strip's word on what runs now, any project: `3 个在跑 · 1 个等你 ·
// 2 个刚完成`, amber when someone waits on the person, a breathing blue dot
// while something runs, a check when only finished ones are left; a click
// opens the running-conversations picker (the same as SPC t r). Nothing while
// nothing runs and nothing finished lately.
import { Check } from "lucide-react";
import { useMatch, useNavigate } from "react-router";
import { useFinishedThreads, useRunningThreads } from "@/core/projects";
import { openRunningPicker } from "@/ui/keys/runningPicker";
import { t } from "@/ui/strings";

export function RunningChip({ className = "" }: { className?: string }) {
  const navigate = useNavigate();
  const threadId = useMatch("/p/:slug/t/:threadId")?.params.threadId ?? null;
  const running = useRunningThreads();
  const finished = useFinishedThreads();
  const threads = running.data ?? [];
  const done = finished.data ?? [];
  if (threads.length === 0 && done.length === 0) return null;
  const waiting = threads.filter((r) => r.waiting).length;
  const tone = waiting > 0 ? "text-warning" : threads.length > 0 ? "text-primary" : "text-muted-foreground";
  return (
    <button
      type="button"
      className={`${className} ${tone} cursor-pointer hover:underline`}
      title={t.keys.runningThreads}
      data-testid="running-chip"
      onClick={() => openRunningPicker(threads, done, threadId, navigate)}
    >
      {threads.length > 0 ? (
        <span className={`size-2 shrink-0 rounded-full ${waiting > 0 ? "bg-warning" : "bg-primary animate-pulse"}`} aria-hidden="true" />
      ) : (
        <Check className="size-3" aria-hidden="true" />
      )}
      {t.runningStrip(threads.length, waiting, done.length)}
    </button>
  );
}
