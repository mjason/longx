// Settings → codex 进程: every codex running right now, across projects —
// what each costs and when it was last used — with a stop per row. The
// reaper (Longx.Codex.Recycler) stops idle ones on its own; this is the
// view of it and the hand on the switch for the rest.
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { listCodexProcesses, stopCodex } from "@/ash_rpc";
import { formatBytes, formatDuration, relativeTime } from "@/core/format";
import { queryKeys, unwrap } from "@/core/projects";
import { Badge } from "@/ui/components/ui/badge";
import { Button } from "@/ui/components/ui/button";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { t } from "@/ui/strings";

const s = t.processesPage;

export type CodexProcess = {
  projectId: string;
  name: string | null;
  slug: string | null;
  osPid: number | null;
  stats: { rssBytes: number; processes: number; cpuMs: number } | null;
  memoryLimit: number | null;
  startedAt: string | null;
  lastTurnAt: string | null;
  turns: number;
  activeTurns: number;
  threads: number;
};

const processesKey = ["codex-processes"] as const;

export function useCodexProcesses() {
  return useQuery({
    queryKey: processesKey,
    refetchInterval: 5_000,
    queryFn: async () => {
      const data = unwrap(await listCodexProcesses({ fields: ["processes", "idleAfterMs"] }));
      return { idleAfterMs: data.idleAfterMs ?? null, processes: data.processes as CodexProcess[] };
    },
  });
}

export function ProcessesSection() {
  const client = useQueryClient();
  const list = useCodexProcesses();
  const stop = useMutation({
    mutationFn: async (p: CodexProcess) => unwrap(await stopCodex({ input: { id: p.projectId, force: false } })),
    onSuccess: (_r, p) => {
      client.invalidateQueries({ queryKey: processesKey });
      client.invalidateQueries({ queryKey: queryKeys.codex(p.projectId) });
      toast.success(s.stopped(p.name ?? p.projectId));
    },
    onError: (e) => toast.error(e instanceof Error ? e.message : String(e)),
  });

  if (list.isPending) return <Skeleton className="h-24 w-full" />;
  if (list.isError) return <p className="text-destructive text-sm">{list.error.message}</p>;
  const { idleAfterMs, processes } = list.data;

  return (
    <div className="flex flex-col gap-4" data-testid="section-processes">
      <p className="text-muted-foreground text-sm">{idleAfterMs ? s.hint(`${Math.round(idleAfterMs / 60000)} 分钟`) : s.hintNoReaper}</p>
      {processes.length === 0 ? (
        <p className="text-muted-foreground rounded-lg border px-4 py-8 text-center text-sm">{s.none}</p>
      ) : (
        <ul className="divide-y rounded-lg border">
          {processes.map((p) => {
            const busy = p.activeTurns > 0;
            return (
              <li key={p.projectId} className="flex flex-col gap-2 px-4 py-3 sm:flex-row sm:items-center sm:justify-between" data-testid={`codex-process-${p.projectId}`}>
                <div className="min-w-0">
                  <div className="flex items-center gap-2">
                    <span className="truncate font-medium">{p.name ?? p.projectId}</span>
                    {busy ? <Badge>{s.busy(p.activeTurns)}</Badge> : <Badge variant="outline">{s.idle}</Badge>}
                  </div>
                  <div className="text-muted-foreground mt-1 flex flex-wrap gap-x-3 gap-y-0.5 font-mono text-xs">
                    <span>{formatBytes(p.stats?.rssBytes ?? 0)}</span>
                    <span>PID {p.osPid ?? "—"}</span>
                    <span>{s.turns(p.turns)}</span>
                    <span>{s.threads(p.threads)}</span>
                    {p.startedAt ? <span>{s.up(formatDuration(Date.now() - new Date(p.startedAt).getTime()))}</span> : null}
                    <span>{p.lastTurnAt ? s.lastTurn(relativeTime(p.lastTurnAt)) : s.noTurnYet}</span>
                  </div>
                </div>
                <Button variant="secondary" size="sm" disabled={busy || stop.isPending} onClick={() => stop.mutate(p)}>
                  {t.stop}
                </Button>
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}
