import { useSandboxStatus } from "@/core/projects";
import { t } from "@/ui/strings";

/** Persistent warning when codex's command sandbox cannot work on this machine. */
export function SandboxBanner() {
  const { data } = useSandboxStatus();
  if (!data || data.status !== "unavailable") return null;
  return (
    <div
      role="alert"
      data-testid="sandbox-banner"
      className="bg-destructive/15 text-destructive-foreground border-destructive/30 border-b px-4 py-2 text-sm"
    >
      <span className="text-destructive font-medium">{t.sandboxUnavailable}</span>
      {data.reason ? <span className="text-muted-foreground ml-2">{t.sandboxReason(data.reason)}</span> : null}
    </div>
  );
}
