import { formatBytes, formatDuration } from "@/core/format";
import { useCodexControls, useCodexInfo } from "@/core/projects";
import { AlertTriangle } from "lucide-react";
import { Alert, AlertDescription, AlertTitle } from "@/ui/components/ui/alert";
import { Badge } from "@/ui/components/ui/badge";
import { Button } from "@/ui/components/ui/button";
import { t } from "@/ui/strings";
import type { ProjectContext } from "../ProjectWindow";

type Worker = {
  phase: string;
  os_pid?: number | null;
  turns: number;
  active_turns: number;
  started_at?: string;
  stats?: { rss_bytes: number; processes: number; cpu_ms: number } | null;
};

/** IDEA's Services tool window, for the project's codex process. */
export function ProcessTool({ ctx }: { ctx: ProjectContext }) {
  const codex = useCodexInfo(ctx.id);
  const controls = useCodexControls(ctx.id);
  const worker = codex.data?.worker as Worker | null | undefined;
  const sample = ctx.sample;
  const stale = codex.data?.stale ?? [];

  return (
    <div className="flex flex-col gap-3 text-sm" data-testid="process-tool">
      {stale.length ? (
        <Alert>
          <AlertTriangle className="size-4" />
          <AlertTitle>{t.codexStaleTitle}</AlertTitle>
          <AlertDescription>
            <ul className="list-disc ps-4">
              {stale.map((reason) => (
                <li key={reason}>{t.codexStaleReasons[reason] ?? reason}</li>
              ))}
            </ul>
            <p>{t.codexStaleHint}</p>
          </AlertDescription>
        </Alert>
      ) : null}
      <div className="flex items-center justify-between">
        <span className="font-medium">{t.codex}</span>
        {worker ? (
          <Badge variant={worker.phase === "ready" ? "default" : "secondary"}>{worker.phase === "ready" ? t.running : t.handshaking}</Badge>
        ) : (
          <Badge variant="outline">{t.stopped}</Badge>
        )}
      </div>
      <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1">
        <dt className="text-muted-foreground">{t.memory}</dt>
        <dd className="font-mono">{formatBytes(sample?.rss_bytes ?? worker?.stats?.rss_bytes ?? 0)}</dd>
        <dt className="text-muted-foreground">{t.processes}</dt>
        <dd className="font-mono">{sample?.processes ?? worker?.stats?.processes ?? 0}</dd>
        <dt className="text-muted-foreground">{t.turns}</dt>
        <dd className="font-mono">{sample?.turns ?? worker?.turns ?? 0}</dd>
        <dt className="text-muted-foreground">{t.uptime}</dt>
        <dd className="font-mono">{sample ? formatDuration(sample.uptime_ms) : "—"}</dd>
        <dt className="text-muted-foreground">PID</dt>
        <dd className="font-mono">{worker?.os_pid ?? "—"}</dd>
        <dt className="text-muted-foreground">{t.home}</dt>
        <dd className="truncate font-mono text-xs" title={codex.data?.home}>{codex.data ? formatBytes(codex.data.bytes) : "—"}</dd>
      </dl>
      <div className="flex gap-2">
        <Button variant="secondary" size="sm" disabled={!worker || controls.stop.isPending} onClick={() => controls.stop.mutate(true)}>
          {t.stop}
        </Button>
        <Button variant="secondary" size="sm" disabled={controls.restart.isPending} onClick={() => controls.restart.mutate()}>
          {t.restart}
        </Button>
      </div>
    </div>
  );
}
