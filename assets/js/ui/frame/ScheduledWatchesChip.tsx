import { useTranslation } from "react-i18next";
import { CalendarClock, CircleDot } from "lucide-react";
import { useState } from "react";
import { Link } from "react-router";
import { useFileContent } from "@/core/workspace";
import { useWatches, type Watch } from "@/core/watches";
import { Popover, PopoverContent, PopoverTrigger } from "@/ui/components/ui/popover";
import { t } from "@/ui/strings";

function scriptPath(path: string, rootPath: string): string | null {
  const prefix = rootPath.endsWith("/") ? rootPath : `${rootPath}/`;
  return path.startsWith(prefix) ? path.slice(prefix.length) : null;
}

function WatchDetails({
  watch,
  projectId,
  rootPath,
}: {
  watch: Watch;
  projectId: string;
  rootPath: string;
}) {
    useTranslation();
  const [open, setOpen] = useState(false);
  const path = scriptPath(watch.path, rootPath);
  const source = useFileContent(projectId, open ? path : null);

  return (
    <details className="border-t px-3 py-2" onToggle={(event) => setOpen(event.currentTarget.open)}>
      <summary className="text-primary cursor-pointer text-xs">{t.watches.inspectScript}</summary>
      {source.isPending ? <p className="text-muted-foreground py-2 text-xs">{t.watches.scriptLoading}</p> : null}
      {source.isError || !path ? <p className="text-destructive py-2 text-xs">{t.watches.scriptUnavailable}</p> : null}
      {source.data?.content !== null && source.data?.content !== undefined ? (
        <pre className="bg-muted/40 mt-2 max-h-48 overflow-auto rounded p-2 text-[11px] whitespace-pre-wrap">
          {source.data.content}
        </pre>
      ) : null}
    </details>
  );
}

function schedule(watch: Watch) {
  if (watch.kind === "once") return `${t.watches.kinds.once} · ${watch.at ? new Date(watch.at).toLocaleString() : "—"}`;
  return `${t.watches.kinds.cron} ${watch.cron ?? "—"}`;
}

/** Enabled project schedules and their script source, visible from the status bar. */
export function ScheduledWatchesChip({
  projectId,
  slug,
  rootPath,
  className = "",
}: {
  projectId: string;
  slug: string;
  rootPath: string;
  className?: string;
}) {
    useTranslation();
  const watches = useWatches(projectId);
  const scheduled = (watches.data ?? [])
    .filter((watch) => watch.enabled && (watch.kind === "cron" || watch.kind === "once"))
    .sort((left, right) => (left.nextDueAt ?? "").localeCompare(right.nextDueAt ?? ""));
  if (scheduled.length === 0) return null;

  return (
    <Popover>
      <PopoverTrigger asChild>
        <button
          type="button"
          className={`${className} text-primary cursor-pointer hover:underline`}
          title={t.watches.title}
          data-testid="scheduled-watches-chip"
        >
          <CalendarClock className="size-3" aria-hidden="true" />
          {t.watches.scheduledChip(scheduled.length)}
        </button>
      </PopoverTrigger>
      <PopoverContent side="top" align="start" className="w-[min(32rem,calc(100vw-1.5rem))] overflow-hidden p-0" data-testid="scheduled-watches-popover">
        <div className="border-b px-3 py-2.5 text-sm font-medium">{t.watches.title}</div>
        <section className="max-h-80 overflow-y-auto">
          {scheduled.map((watch) => {
            const due = watch.nextDueAt ? new Date(watch.nextDueAt).toLocaleString() : "—";
            return (
              <article key={watch.id} className="border-b last:border-0">
                <div className="px-3 py-3">
                  <Link className="flex items-center gap-2 text-sm font-medium hover:underline" to={`/p/${slug}/settings`}>
                    {watch.runningSince ? <CircleDot className="text-primary size-3 animate-pulse" aria-label={t.watches.states.running} /> : null}
                    {watch.name}
                  </Link>
                  <p className="text-muted-foreground mt-1 text-xs">{schedule(watch)}</p>
                  <p className="text-muted-foreground mt-1 text-xs">{t.watches.nextDue(due)}</p>
                </div>
                <WatchDetails watch={watch} projectId={projectId} rootPath={rootPath} />
              </article>
            );
          })}
        </section>
      </PopoverContent>
    </Popover>
  );
}
