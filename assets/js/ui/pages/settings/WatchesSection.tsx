// Settings → 监控与定时: every project's watches (Longx.Watches) — the
// running ones first — with their schedule, state, last and next run, so
// the person knows what runs by itself on this machine. Refreshed while
// shown. Switching, trying and deleting live on the project's page.
import { Link } from "react-router";
import { relativeTime } from "@/core/format";
import { useAllWatches, watchState, type WatchOverview } from "@/core/watches";
import { Badge } from "@/ui/components/ui/badge";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { t } from "@/ui/strings";

const s = t.watches;

export function scheduleText(w: Pick<WatchOverview, "kind" | "cron" | "at">): string {
  if (w.kind === "cron") return w.cron ? `${s.kinds.cron} ${w.cron}` : "—";
  if (w.kind === "once") return `${s.kinds.once} ${w.at ? new Date(w.at).toLocaleString() : ""}`;
  return s.kinds.webhook!;
}

export function stateBadge(w: Pick<WatchOverview, "enabled" | "disabledReason" | "runningSince">) {
  const state = watchState(w);
  const label = state === "running" && w.runningSince ? s.runningFor(relativeTime(w.runningSince)) : s.states[state];
  const variant = state === "running" ? "default" : state === "on" ? "secondary" : state === "load_error" || state === "budget" ? "destructive" : "outline";
  return <Badge variant={variant} data-testid="watch-state">{label}</Badge>;
}

export function lastRunText(w: Pick<WatchOverview, "lastRunAt" | "lastDurationMs" | "lastError">): string {
  if (!w.lastRunAt) return s.neverRan;
  return s.lastRun(relativeTime(w.lastRunAt), w.lastDurationMs ?? 0) + (w.lastError ? ` · ${w.lastError}` : "");
}

export function WatchesSection() {
  const watches = useAllWatches();

  if (watches.isPending) return <Skeleton className="h-24 w-full" data-testid="section-watches" />;
  if (watches.isError) return <p className="text-destructive text-sm">{watches.error.message}</p>;

  return (
    <div className="space-y-4" data-testid="section-watches">
      <p className="text-muted-foreground text-sm">{s.hint}</p>
      {watches.data.length === 0 ? (
        <p className="text-muted-foreground text-sm">{s.allNone}</p>
      ) : (
        <ul className="divide-y rounded-lg border">
          {watches.data.map((w) => (
            <li key={w.id} className="flex flex-col gap-1 px-4 py-3" data-testid="watch-row">
              <div className="flex flex-wrap items-center gap-2">
                <span className="font-medium">{w.name}</span>
                {stateBadge(w)}
                <span className="text-muted-foreground text-sm">{scheduleText(w)}</span>
                <span className="text-muted-foreground ml-auto text-sm">{w.projectName}</span>
                {w.projectSlug ? (
                  <Link to={`/p/${w.projectSlug}/settings`} className="text-primary text-sm underline-offset-2 hover:underline">
                    {s.openProject}
                  </Link>
                ) : null}
              </div>
              <div className="text-muted-foreground flex flex-wrap gap-x-4 text-xs">
                <span>{s.columns.last}: {lastRunText(w)}</span>
                {w.nextDueAt ? <span>{s.columns.next}: {new Date(w.nextDueAt).toLocaleString()}</span> : null}
                <span>{s.counts(w.runs, w.sends)}</span>
                {w.lastSentTo ? <span>{s.sentTo(w.lastSentTo)}</span> : null}
              </div>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
