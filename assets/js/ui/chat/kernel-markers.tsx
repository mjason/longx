import { useTranslation } from "react-i18next";
import { t } from "@/ui/strings";
import { useState } from "react";
import { ChevronDown } from "lucide-react";
import { cn } from "@/lib/utils";
import { formatDuration } from "@/core/format";

// Kernel lifecycle markers share an on-demand chunk, not the composer entry.
export function JobNoticeView({ name, status, exitCode, durationMs, text }: { name: string; status: string; exitCode: number | null; durationMs: number | null; text: string }) {
  useTranslation();
  const [open, setOpen] = useState(false);
  const how = status === "review" ? `${t.jobWork.states.processing} · ${name}` : status === "exited" ? t.jobEnded(name) : t.jobStopped(name);
  const bits = [how, exitCode !== null ? t.jobExitCode(exitCode) : null, durationMs !== null ? formatDuration(durationMs) : null].filter(Boolean).join(" · ");
  return (
    <div className="my-2 flex min-w-0 flex-col gap-1" data-testid="job-notice">
      <button type="button" className="text-muted-foreground flex min-w-0 items-center gap-2 text-left text-[11px]" aria-expanded={open} onClick={() => setOpen((v) => !v)}>
        <span className="bg-border h-px w-6 shrink-0" />
        <span className={cn("min-w-0 truncate", status === "exited" && exitCode === 0 ? "" : "text-warning")}>{bits}</span>
        <ChevronDown className={cn("size-3 shrink-0 transition-transform", open && "rotate-180")} aria-hidden />
        <span className="bg-border h-px flex-1" />
      </button>
      {open ? <pre className="bg-muted/50 text-muted-foreground overflow-x-auto rounded-md p-2 text-[11px] whitespace-pre-wrap">{text}</pre> : null}
    </div>
  );
}

export function GoalContinuationView({ round, objective }: { round: number | null; objective: string | null }) {
  useTranslation();
  const label = round === null ? t.goalRoundUnknown : t.goalRound(round);
  return (
    <div role="separator" aria-label={label}
      className="text-muted-foreground my-2 flex min-w-0 items-center gap-2 text-[11px]"
      data-testid="goal-continuation">
      <span className="bg-border h-px w-6 shrink-0" />
      <span className="shrink-0">{label}</span>
      {objective ? <span className="min-w-0 truncate opacity-70" title={objective}>{objective}</span> : null}
      <span className="bg-border h-px flex-1" />
    </div>
  );
}

export default function CompactionView({ error }: { error?: string }) {
  useTranslation();
  if (error) return (
    <div role="alert" className="my-2 text-xs text-destructive" data-testid="compaction-failed">
      <div>{t.compactionFailed}</div>
    </div>
  );
  return (
    <div role="separator" aria-label={t.compacted}
      className="text-muted-foreground my-2 flex items-center gap-2 text-[11px]"
      data-testid="compaction">
      <span className="bg-border h-px flex-1" />
      <span>{t.compacted}</span>
      <span className="bg-border h-px flex-1" />
    </div>
  );
}
