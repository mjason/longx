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
  const noNet = status.data.status === "no_net_isolation";
  const apparmor = status.data.reason?.startsWith("apparmor:") ?? false;
  return (
    <div className="flex max-w-2xl flex-col gap-4" data-testid="section-sandbox">
      <p className="text-muted-foreground text-sm">{t.sandboxPage.hint}</p>
      <div className="flex items-start gap-3 rounded-lg border p-4">
        {ok ? <ShieldCheck className="text-success mt-0.5 size-5 shrink-0" /> : <ShieldAlert className="text-warning mt-0.5 size-5 shrink-0" />}
        <div className="min-w-0 flex-1">
          <p className="font-medium">{ok ? t.sandboxPage.ok : noNet ? t.sandboxPage.noNet : apparmor ? t.sandboxPage.apparmor : t.sandboxPage.unavailable}</p>
          {noNet ? <p className="text-muted-foreground mt-1 text-xs">{t.sandboxPage.noNetHint}</p> : null}
          {apparmor ? (
            <div className="mt-2 flex flex-col gap-2 text-xs">
              <p className="text-muted-foreground">{t.sandboxPage.apparmorHint}</p>
              <pre className="bg-muted overflow-x-auto rounded-md p-3 font-mono whitespace-pre">{t.sandboxPage.apparmorFix}</pre>
              <p className="text-muted-foreground">{t.sandboxPage.apparmorAfter}</p>
            </div>
          ) : null}
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
