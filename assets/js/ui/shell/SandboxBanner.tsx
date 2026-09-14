import { useSandboxStatus } from "@/core/projects";
import { t } from "@/ui/strings";

/**
 * Persistent warning when codex's command sandbox cannot work on this
 * machine (red), or only for commands allowed to reach the network (amber:
 * a project with network access on is fine).
 */
export function SandboxBanner() {
  const { data } = useSandboxStatus();
  if (!data || data.status === "ok") return null;
  const noNet = data.status === "no_net_isolation";
  const apparmor = data.reason?.startsWith("apparmor:") ?? false;
  return (
    <div
      role="alert"
      data-testid="sandbox-banner"
      className={`border-b px-4 py-2 text-sm ${noNet ? "bg-warning/15 border-warning/30" : "bg-destructive/15 text-destructive-foreground border-destructive/30"}`}
    >
      <span className={`font-medium ${noNet ? "text-warning" : "text-destructive"}`}>{noNet ? t.sandboxNoNet : apparmor ? t.sandboxAppArmor : t.sandboxUnavailable}</span>
      {data.reason ? <span className="text-muted-foreground ml-2">{t.sandboxReason(data.reason)}</span> : null}
    </div>
  );
}
