// Settings → 沙箱与权限: the bubblewrap probe's verdict, with a way to run it again.
import { RefreshCw, ShieldAlert, ShieldCheck } from "lucide-react";
import { toast } from "sonner";
import { useProbeSandbox } from "@/core/ai";
import { relativeTime } from "@/core/format";
import { useSandboxStatus } from "@/core/projects";
import { Button } from "@/ui/components/ui/button";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { t } from "@/ui/strings";

export function SandboxSection() {
  const status = useSandboxStatus();
  const probe = useProbeSandbox();
  if (status.isPending) return <Skeleton className="h-24 w-full" data-testid="section-sandbox" />;
  if (status.isError) return <p className="text-destructive text-sm">{status.error.message}</p>;
  const ok = status.data.status === "ok";
  return (
    <div className="flex max-w-2xl flex-col gap-4" data-testid="section-sandbox">
      <p className="text-muted-foreground text-sm">{t.sandboxPage.hint}</p>
      <div className="flex items-start gap-3 rounded-lg border p-4">
        {ok ? <ShieldCheck className="text-success mt-0.5 size-5 shrink-0" /> : <ShieldAlert className="text-warning mt-0.5 size-5 shrink-0" />}
        <div className="min-w-0 flex-1">
          <p className="font-medium">{ok ? t.sandboxPage.ok : t.sandboxPage.unavailable}</p>
          {status.data.reason ? (
            <p className="text-muted-foreground mt-1 font-mono text-xs break-words">
              {t.sandboxPage.reason}: {status.data.reason}
            </p>
          ) : null}
          {status.data.checkedAt ? <p className="text-muted-foreground mt-1 text-xs">{t.sandboxPage.checkedAt(relativeTime(status.data.checkedAt))}</p> : null}
        </div>
        <Button variant="outline" size="sm" disabled={probe.isPending} onClick={() => probe.mutate(undefined, { onSuccess: () => toast.success(t.sandboxPage.probed), onError: (e) => toast.error(e.message) })}>
          <RefreshCw className={`size-4 ${probe.isPending ? "animate-spin" : ""}`} /> {t.sandboxPage.probe}
        </Button>
      </div>
    </div>
  );
}
