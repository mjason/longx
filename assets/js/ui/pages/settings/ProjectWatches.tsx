// A project's watches on its settings page (Longx.Watches): each with its
// schedule, state, last run and output; a switch, a dry run (what the
// script would log and send, in a dialog) and delete (the file goes).
import { useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { toast } from "sonner";
import { usePromoteLocal } from "@/core/agent";
import { useWatchActions, useWatches, type DryRun, type Watch } from "@/core/watches";
import { Button } from "@/ui/components/ui/button";
import { Dialog, DialogBody, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/ui/components/ui/dialog";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { Switch } from "@/ui/components/ui/switch";
import { t } from "@/ui/strings";
import { lastRunText, scheduleText, stateBadge } from "./WatchesSection";

const s = t.watches;

/** a path under the project root, shown relative to it */
function relative(path: string, root: string): string {
  const prefix = root.endsWith("/") ? root : root + "/";
  return path.startsWith(prefix) ? path.slice(prefix.length) : path;
}

export function ProjectWatches({
  projectId,
  rootPath,
  trusted,
  sharedFiles,
}: {
  projectId: string;
  rootPath: string;
  /** the project's trust switch: shared/watches/ runs only with it on */
  trusted: boolean;
  /** the project's .longx files (agent_definition), to point at shared watches the switch keeps off */
  sharedFiles: string[];
}) {
  const watches = useWatches(projectId);
  const actions = useWatchActions(projectId);
  const promote = usePromoteLocal(projectId);
  const client = useQueryClient();
  const sharedWatches = sharedFiles.filter((f) => /(^|\/)shared\/watches\/[^/]+\.exs$/.test(f)).map((f) => f.split("/").pop()!);

  const promoteWatch = (watch: Watch) =>
    promote.mutate(`watches/${watch.name}.exs`, {
      onSuccess: (r) => {
        toast.success(s.promoted(r.path));
        void client.invalidateQueries({ queryKey: ["watches"] });
      },
      onError: (e: Error) => toast.error(e.message),
    });
  const [trying, setTrying] = useState<{ watch: Watch; result: DryRun | null } | null>(null);

  const tryRun = async (watch: Watch) => {
    setTrying({ watch, result: null });
    try {
      setTrying({ watch, result: await actions.dryRun.mutateAsync(watch.id) });
    } catch (e) {
      toast.error((e as Error).message);
      setTrying(null);
    }
  };

  const remove = async (watch: Watch) => {
    if (!window.confirm(s.removeConfirm(watch.name))) return;
    try {
      await actions.remove.mutateAsync(watch.id);
    } catch (e) {
      toast.error((e as Error).message);
    }
  };

  return (
    <section className="space-y-3" data-testid="project-watches">
      <h2 className="text-lg font-medium">{s.title}</h2>
      <p className="text-muted-foreground text-sm">{s.projectHint}</p>
      {!trusted && sharedWatches.length > 0 ? (
        <p className="text-warning text-sm" data-testid="shared-watches-untrusted">
          {s.sharedUntrusted(sharedWatches.join("、"))}
        </p>
      ) : null}
      {watches.isPending ? <Skeleton className="h-16 w-full" /> : null}
      {watches.isError ? <p className="text-destructive text-sm">{watches.error.message}</p> : null}
      {watches.data?.length === 0 ? <p className="text-muted-foreground text-sm">{s.none}</p> : null}
      {watches.data && watches.data.length > 0 ? (
        <ul className="divide-y rounded-lg border">
          {watches.data.map((w) => (
            <li key={w.id} className="flex flex-col gap-2 px-4 py-3" data-testid="watch-row">
              <div className="flex flex-wrap items-center gap-2">
                <span className="font-medium">{w.name}</span>
                {stateBadge(w)}
                <span className="text-muted-foreground text-sm">{scheduleText(w)}</span>
                <span className="text-muted-foreground text-xs">{s.layer[w.layer]}</span>
                <div className="ml-auto flex items-center gap-2">
                  {w.layer === "local" ? (
                    <Button variant="outline" size="sm" onClick={() => promoteWatch(w)} disabled={promote.isPending}>
                      {s.promote}
                    </Button>
                  ) : null}
                  <Button variant="outline" size="sm" onClick={() => tryRun(w)} disabled={!!w.runningSince}>
                    {s.dryRun}
                  </Button>
                  <Switch checked={w.enabled} aria-label={w.enabled ? s.disable : s.enable} onCheckedChange={(enabled) => actions.toggle.mutate({ id: w.id, enabled })} />
                  <Button variant="ghost" size="sm" className="text-destructive" onClick={() => remove(w)}>
                    {s.remove}
                  </Button>
                </div>
              </div>
              <div className="text-muted-foreground flex flex-wrap gap-x-4 text-xs">
                <span>{s.columns.last}: {lastRunText(w)}</span>
                {w.nextDueAt ? <span>{s.columns.next}: {new Date(w.nextDueAt).toLocaleString()}</span> : null}
                <span>{s.counts(w.runs, w.sends)}</span>
                {w.lastSentTo ? <span>{s.sentTo(w.lastSentTo)}</span> : null}
              </div>
              {w.loadError ? <p className="text-destructive text-xs whitespace-pre-wrap">{relative(w.loadError, rootPath)}</p> : null}
              {w.lastOutput ? <pre className="bg-muted/40 max-h-32 overflow-auto rounded p-2 text-xs whitespace-pre-wrap">{w.lastOutput}</pre> : null}
              {w.kind === "webhook" && w.webhookToken ? (
                <p className="text-muted-foreground text-xs">
                  {s.webhook}: <code>POST /hooks/{w.webhookToken}</code>
                </p>
              ) : null}
              <p className="text-muted-foreground text-xs">
                {s.file}: <code>{relative(w.path, rootPath)}</code>
              </p>
            </li>
          ))}
        </ul>
      ) : null}

      <Dialog open={trying !== null} onOpenChange={(open) => !open && setTrying(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{trying ? s.dryRunTitle(trying.watch.name) : ""}</DialogTitle>
            <DialogDescription>{s.dryRunHint}</DialogDescription>
          </DialogHeader>
          <DialogBody className="space-y-3 text-sm">
            {trying && !trying.result ? <Skeleton className="h-12 w-full" /> : null}
            {trying?.result ? (
              <>
                <p className={trying.result.ok ? "text-success" : "text-destructive"}>
                  {trying.result.ok ? s.dryRunOk : s.dryRunFailed} · <code>{trying.result.result}</code>
                </p>
                {trying.result.log.length > 0 ? (
                  <div>
                    <p className="text-muted-foreground text-xs">{s.logged}</p>
                    <pre className="bg-muted/40 rounded p-2 text-xs whitespace-pre-wrap">{trying.result.log.join("\n")}</pre>
                  </div>
                ) : null}
                <div>
                  <p className="text-muted-foreground text-xs">{s.wouldSend}</p>
                  {trying.result.sends.length === 0 ? (
                    <p className="text-muted-foreground text-xs">{s.nothingSent}</p>
                  ) : (
                    <pre className="bg-muted/40 rounded p-2 text-xs whitespace-pre-wrap">{trying.result.sends.join("\n")}</pre>
                  )}
                </div>
              </>
            ) : null}
          </DialogBody>
        </DialogContent>
      </Dialog>
    </section>
  );
}
