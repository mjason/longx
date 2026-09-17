// Settings → 请求记录: the gateway's last requests (Longx.AI.Gateway.Log) —
// what the kernel asked the provider for and what came of it, newest first. The
// place to look when the level or the model on screen does not match what
// the provider was asked; refreshed every few seconds while shown.
import { useQuery } from "@tanstack/react-query";
import { ChevronDown, ChevronRight, RefreshCw } from "lucide-react";
import { useState } from "react";
import { gatewayRequests } from "@/ash_rpc";
import { formatDuration } from "@/core/format";
import { unwrap } from "@/core/projects";
import { Button } from "@/ui/components/ui/button";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { t } from "@/ui/strings";

const s = t.requestsPage;

export type GatewayRequest = {
  id: number;
  at: string;
  threadId: string | null;
  turnId: string | null;
  requestKind: string | null;
  model: string | null;
  upstreamId: string | null;
  provider: string | null;
  effort: string | null;
  summary: string | null;
  tools: string[];
  inputItems: number;
  inputChars: number;
  instructionsChars: number;
  maxOutputTokens: number | null;
  status: number | null;
  durationMs: number | null;
  error: string | null;
};

export function useGatewayRequests(limit = 200) {
  return useQuery({
    queryKey: ["gateway-requests", limit],
    refetchInterval: 5_000,
    queryFn: async () => {
      const data = unwrap(await gatewayRequests({ fields: ["requests", "keep"], input: { limit } }));
      return { keep: data.keep, requests: data.requests as GatewayRequest[] };
    },
  });
}

function timeOf(iso: string): string {
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? iso : d.toLocaleTimeString();
}

function statusClass(status: number | null): string {
  if (status === null) return "text-muted-foreground";
  return status >= 400 ? "text-destructive" : "text-success";
}

export function RequestsSection() {
  const list = useGatewayRequests();
  const [open, setOpen] = useState<number | null>(null);
  if (list.isPending) return <Skeleton className="h-24 w-full" data-testid="section-requests" />;
  if (list.isError) return <p className="text-destructive text-sm">{list.error.message}</p>;
  const { keep, requests } = list.data;
  return (
    <div className="flex flex-col gap-3" data-testid="section-requests">
      <div className="flex items-start justify-between gap-3">
        <p className="text-muted-foreground text-sm">{s.hint(keep)}</p>
        <Button variant="outline" size="sm" className="shrink-0" onClick={() => void list.refetch()}>
          <RefreshCw className="size-3.5" /> {s.refresh}
        </Button>
      </div>
      {requests.length === 0 ? (
        <p className="text-muted-foreground text-sm">{s.empty}</p>
      ) : (
        <ul className="divide-y rounded-lg border text-xs">
          <li className="text-muted-foreground flex items-center gap-3 px-3 py-1.5" aria-hidden="true">
            <span className="size-6 shrink-0" />
            <span className="w-20 shrink-0">{s.columns.at}</span>
            <span className="min-w-0 flex-1">{s.columns.model}</span>
            <span className="w-14 shrink-0 text-center">{s.columns.effort}</span>
            <span className="hidden w-16 shrink-0 sm:inline">{s.columns.kind}</span>
            <span className="w-10 shrink-0 text-right">{s.columns.status}</span>
            <span className="w-14 shrink-0 text-right">{s.columns.duration}</span>
          </li>
          {requests.map((r) => (
            <li key={r.id} className="px-3 py-2" data-testid="request-row">
              <div className="flex items-center gap-3">
                <button
                  type="button"
                  className="text-muted-foreground flex size-6 shrink-0 items-center justify-center rounded hover:bg-accent"
                  aria-label={s.details}
                  onClick={() => setOpen(open === r.id ? null : r.id)}
                >
                  {open === r.id ? <ChevronDown className="size-3.5" /> : <ChevronRight className="size-3.5" />}
                </button>
                <span className="text-muted-foreground w-20 shrink-0 font-mono">{timeOf(r.at)}</span>
                <span className="min-w-0 flex-1 truncate font-mono">
                  {r.model ?? "—"}
                  {r.upstreamId && r.upstreamId !== r.model ? <span className="text-muted-foreground"> → {r.upstreamId}</span> : null}
                </span>
                <span className={`w-14 shrink-0 text-center ${r.effort ? "font-medium" : "text-muted-foreground"}`} title={s.columns.effort}>
                  {r.effort ?? s.noEffort}
                </span>
                <span className="text-muted-foreground hidden w-16 shrink-0 sm:inline">{r.requestKind ?? ""}</span>
                <span className={`w-10 shrink-0 text-right font-mono ${statusClass(r.status)}`}>{r.status ?? "…"}</span>
                <span className="text-muted-foreground w-14 shrink-0 text-right font-mono">{r.durationMs === null ? "" : formatDuration(r.durationMs)}</span>
              </div>
              {r.error ? <p className="text-destructive mt-1 pl-9">{r.error}</p> : null}
              {open === r.id ? (
                <dl className="text-muted-foreground mt-2 grid gap-1 pl-9">
                  <div>
                    {s.reasoning}: {r.effort ?? s.noEffort}
                    {r.summary ? ` · summary ${r.summary}` : ""}
                  </div>
                  <div>
                    {s.thread} <span className="font-mono">{r.threadId ?? "—"}</span> · {s.turn} <span className="font-mono">{r.turnId ?? "—"}</span>
                  </div>
                  <div>
                    {s.tools}: {r.tools.length ? r.tools.join(", ") : s.noTools}
                  </div>
                  <div>
                    {s.input(r.inputItems, r.inputChars)} · {s.instructions(r.instructionsChars)}
                    {r.maxOutputTokens ? ` · ${s.maxOutput(r.maxOutputTokens)}` : ""}
                    {r.provider ? ` · ${r.provider}` : ""}
                  </div>
                </dl>
              ) : null}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
