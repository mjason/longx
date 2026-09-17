// Settings → 系统依赖: the command-line tools the agent leans on — found
// (with its version) or missing, and the one install line for this machine.
import { CheckCircle2, RefreshCw, XCircle } from "lucide-react";
import { toast } from "sonner";
import { useCheckDependencies, useDependencies } from "@/core/dependencies";
import { Button } from "@/ui/components/ui/button";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { t } from "@/ui/strings";

const s = t.dependenciesPage;

export function DependenciesSection() {
  const report = useDependencies();
  const check = useCheckDependencies();
  if (report.isPending) return <Skeleton className="h-24 w-full" />;
  if (report.isError) return <p className="text-destructive text-sm">{report.error.message}</p>;
  const r = report.data;
  return (
    <div className="flex flex-col gap-4" data-testid="section-dependencies">
      <p className="text-muted-foreground text-sm">{s.hint}</p>
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className={r.missing > 0 ? "text-warning text-sm font-medium" : "text-success text-sm font-medium"}>
          {r.missing > 0 ? s.missing(r.missing) : s.allFound}
        </p>
        <Button size="sm" variant="outline" onClick={() => check.mutate(undefined, { onError: (e: Error) => toast.error(e.message) })} disabled={check.isPending}>
          <RefreshCw className={`size-4 ${check.isPending ? "animate-spin" : ""}`} /> {s.recheck}
        </Button>
      </div>
      {r.installCommand ? (
        <div className="rounded-lg border p-3" data-testid="dependencies-install">
          <p className="text-muted-foreground mb-1 text-xs">{s.installHint(r.os)}</p>
          <pre className="overflow-x-auto font-mono text-xs">{r.installCommand}</pre>
        </div>
      ) : null}
      <ul className="divide-y rounded-lg border" data-testid="dependencies-list">
        {r.tools.map((tool) => (
          <li key={tool.name} className="flex items-center justify-between gap-3 px-3 py-2 text-sm">
            <span className="flex items-center gap-2">
              {tool.found ? <CheckCircle2 className="text-success size-4" /> : <XCircle className="text-warning size-4" />}
              <span className="font-mono">{tool.name}</span>
              {tool.found && tool.command !== tool.name ? <span className="text-muted-foreground text-xs">{tool.command}</span> : null}
            </span>
            <span className="text-muted-foreground font-mono text-xs">{tool.found ? (tool.version ?? s.versionUnknown) : s.notFound}</span>
          </li>
        ))}
      </ul>
    </div>
  );
}
