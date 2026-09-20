// Settings → 进程: the commands the agents are running right now — what,
// for which session (the sub-agent named), since when — refreshed every two
// seconds while shown, each with 结束: the shim tree is killed and the model
// is told the person ended it. For the backtest that never returns and the
// loop nobody meant.
import { useState } from "react";
import { Link } from "react-router";
import { toast } from "sonner";
import { formatDuration } from "@/core/format";
import { useKillCommand, useRunningCommands, type RunningCommand } from "@/core/commands";
import { Button } from "@/ui/components/ui/button";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle } from "@/ui/components/ui/alert-dialog";
import { t } from "@/ui/strings";

const s = t.processes;

export function ProcessesSection() {
  const commands = useRunningCommands();
  const kill = useKillCommand();
  const [ending, setEnding] = useState<RunningCommand | null>(null);

  if (commands.isPending) return <Skeleton className="h-24 w-full" data-testid="section-processes" />;
  if (commands.isError) return <p className="text-destructive text-sm">{commands.error.message}</p>;

  return (
    <div className="space-y-4" data-testid="section-processes">
      <p className="text-muted-foreground text-sm">{s.hint}</p>
      {commands.data.length === 0 ? (
        <p className="text-muted-foreground text-sm">{s.none}</p>
      ) : (
        <ul className="divide-y rounded-lg border">
          {commands.data.map((c) => (
            <li key={c.id} className="flex flex-col gap-1.5 p-3 sm:flex-row sm:items-start sm:gap-4" data-testid="command-row">
              <div className="min-w-0 flex-1">
                <code className="block break-all font-mono text-xs">{c.cmd}</code>
                <div className="text-muted-foreground mt-1 flex flex-wrap items-center gap-x-3 gap-y-0.5 text-xs">
                  {c.session ? (
                    <>
                      <span>
                        {c.session.slug} · {c.session.title}
                        {c.session.agent ? <> · <code className="font-mono">{c.session.agent}</code></> : null}
                      </span>
                      <Link to={`/p/${c.session.slug}/t/${c.session.rootRowId}`} className="text-primary hover:underline">
                        {s.openSession}
                      </Link>
                    </>
                  ) : (
                    <span>{s.noSession}</span>
                  )}
                  {c.elapsedMs !== null ? <span>{s.runningFor(formatDuration(c.elapsedMs))}</span> : null}
                  {c.osPid ? <span className="font-mono">pid {c.osPid}</span> : null}
                </div>
              </div>
              <Button size="sm" variant="outline" className="shrink-0" onClick={() => setEnding(c)} disabled={kill.isPending}>
                {s.end}
              </Button>
            </li>
          ))}
        </ul>
      )}
      <AlertDialog open={ending !== null} onOpenChange={(open) => (open ? null : setEnding(null))}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{s.confirmTitle}</AlertDialogTitle>
            <AlertDialogDescription className="break-all font-mono text-xs">{ending?.cmd ?? ""}</AlertDialogDescription>
          </AlertDialogHeader>
          <p className="text-muted-foreground text-sm">{s.confirmHint}</p>
          <AlertDialogFooter>
            <AlertDialogCancel>{t.cancel}</AlertDialogCancel>
            <AlertDialogAction
              className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
              onClick={() => {
                if (!ending) return;
                kill.mutate(ending.id, {
                  onError: (e) => toast.error(e.message),
                  onSuccess: () => toast.success(s.ended),
                });
                setEnding(null);
              }}
            >
              {s.confirm}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}
