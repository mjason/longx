import { toast } from "sonner";
import { browserBusy } from "@/core/browser";
import { useComputerInstall, useComputerStatus } from "@/core/computer";
import { DownloadBar } from "@/ui/components/DownloadBar";
import { Button } from "@/ui/components/ui/button";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { t } from "@/ui/strings";

export function ComputerCard() {
  const status = useComputerStatus();
  const install = useComputerInstall();
  const st = status.data;
  const s = t.computer;
  const installed = !!st?.path;
  const busy = !!st && browserBusy(st.stage);
  const fail = (e: Error) => toast.error(e.message);

  return (
    <section className="rounded-lg border p-3" data-testid="computer-settings">
      <h3 className="text-sm font-medium">{s.title}</h3>
      <p className="text-muted-foreground mt-0.5 text-xs">{s.hint}</p>
      {status.isPending ? <Skeleton className="mt-3 h-8 w-full" /> : null}
      {status.isError ? <p role="alert" className="text-destructive mt-3 text-xs">{status.error.message}</p> : null}
      {st ? (
        <div className="mt-3 flex flex-col gap-2">
          <p className="text-muted-foreground text-xs">{s.version(st.latest, st.target)}</p>
          {busy ? (
            <DownloadBar label={t.agentKernel.browserStages[st.stage] ?? st.stage} received={st.received} total={st.total} />
          ) : (
            <>
              {installed ? (
                <p className="text-muted-foreground break-all font-mono text-xs">
                  {st.source === "env" ? s.override(st.path!) : s.installed(st.path!)}
                </p>
              ) : null}
              {st.stage === "failed" ? <p role="alert" className="text-destructive text-xs">{s.failed(st.error ?? "")}</p> : null}
              {st.upgradable ? <p className="text-xs">{s.upgradable(st.installedVersion, st.latest)}</p> : null}
              {!installed && st.stage !== "failed" && st.target ? (
                <p className="text-muted-foreground text-xs">{s.notInstalled(st.downloadSize)}</p>
              ) : null}
              {!st.target && !installed ? <p className="text-warning text-xs">{s.unsupported}</p> : null}
              {st.target && (!installed || st.upgradable || st.stage === "failed") && st.source !== "env" ? (
                <Button size="sm" variant="outline" className="self-start" disabled={install.isPending}
                  onClick={() => install.mutate(undefined, { onError: fail })}>
                  {st.stage === "failed" ? t.agentKernel.browserRetry : st.upgradable ? t.agentKernel.browserUpgrade : t.agentKernel.browserDownload}
                </Button>
              ) : null}
            </>
          )}
          {st.appPath ? <p className="text-muted-foreground break-all font-mono text-xs">{s.appPath(st.appPath)}</p> : null}
          <p className="text-muted-foreground text-xs">
            {st.target?.startsWith("darwin-") ? s.macPermissions : st.target?.startsWith("windows-") ? s.windowsSession : st.target?.startsWith("linux-") ? s.linuxSession : null}
          </p>
        </div>
      ) : null}
      <p className="text-muted-foreground mt-3 text-xs">{s.scope}</p>
    </section>
  );
}
