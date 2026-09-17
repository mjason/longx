import { AlertCircle, CheckCircle2, ChevronRight, Loader2, Undo2, XCircle } from "lucide-react";
import { useState } from "react";
import { useParams } from "react-router";
import { toast } from "sonner";
import { relativeTime } from "@/core/format";
import { fetchRestoreProposal, useRestoreFiles, useTurns, type RestoreProposal } from "@/core/projects";
import { parseDiff } from "@/ui/chat/toolkit";
import { CheckpointHistory, type Checkpoint } from "@/ui/components/assistant-ui/elements/checkpoint-history";
import { CodeDiff } from "@/ui/components/assistant-ui/elements/code-diff";
import { Button } from "@/ui/components/ui/button";
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from "@/ui/components/ui/collapsible";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/ui/components/ui/dialog";
import { Label } from "@/ui/components/ui/label";
import { RadioGroup, RadioGroupItem } from "@/ui/components/ui/radio-group";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { t } from "@/ui/strings";
import type { ProjectContext } from "../ProjectWindow";

type Turn = NonNullable<ReturnType<typeof useTurns>["data"]>[number];

const STATUS_ICON: Record<string, typeof CheckCircle2> = {
  in_progress: Loader2,
  completed: CheckCircle2,
  failed: XCircle,
  interrupted: AlertCircle,
  reverted: Undo2,
};

/**
 * IDEA's history/changes tab, for us: the thread's turns with their git
 * bookmarks — what each one changed, and going back to before one.
 */
export function TurnsTool(_props: { ctx: ProjectContext }) {
  const { threadId } = useParams();
  const turns = useTurns(threadId);
  const [restoring, setRestoring] = useState<Turn | null>(null);

  if (!threadId) return <p className="text-muted-foreground text-sm">{t.pickThread}</p>;
  if (turns.isPending) return <Skeleton className="h-16 w-full" />;
  if (turns.isError) return <p className="text-destructive text-sm">{turns.error.message}</p>;

  // every turn that started from a commit is a point to fall back to; "now" is HEAD
  const checkpoints: Checkpoint[] = turns.data
    .map((turn, i) => ({ turn, i }))
    .filter(({ turn }) => turn.commitBefore && turn.status !== "reverted" && turn.status !== "in_progress")
    .map(({ turn, i }) => ({ id: turn.id, label: t.checkpointBefore(i + 1, turn.userText ?? ""), at: relativeTime(turn.startedAt), files: turn.diff ? splitDiff(turn.diff).length : 0 }));

  return (
    <div className="flex flex-col gap-2" data-testid="turns-tool">
      {turns.data.length === 0 ? <p className="text-muted-foreground text-sm">{t.noTurns}</p> : null}
      {checkpoints.length ? (
        <CheckpointHistory
          checkpoints={[...checkpoints, { id: "now", label: t.checkpointNow }]}
          currentId="now"
          labels={t.checkpoints}
          onRestore={(id) => setRestoring(turns.data.find((turn) => turn.id === id) ?? null)}
          className="max-w-none"
          data-testid="checkpoints"
        />
      ) : null}
      {turns.data.map((turn, i) => (
        <TurnRow key={turn.id} turn={turn} index={i + 1} />
      ))}
      <RestoreDialog turn={restoring} threadId={threadId} onClose={() => setRestoring(null)} />
    </div>
  );
}

function TurnRow({ turn, index }: { turn: Turn; index: number }) {
  const Icon = STATUS_ICON[turn.status] ?? CheckCircle2;
  const files = turn.diff ? splitDiff(turn.diff) : [];
  return (
    <div className="rounded-lg border p-2 text-sm" data-testid="turn-row">
      <div className="flex items-start gap-2">
        <Icon className={`mt-0.5 size-4 shrink-0 ${turn.status === "in_progress" ? "animate-spin" : ""} ${turn.status === "failed" ? "text-destructive" : "text-muted-foreground"}`} />
        <div className="min-w-0 flex-1">
          <p className="truncate" title={turn.userText ?? ""}>
            <span className="text-muted-foreground mr-1 font-mono text-xs">#{index}</span>
            {turn.userText}
          </p>
          <p className="text-muted-foreground flex flex-wrap gap-x-2 text-xs">
            <span>{t.turnStatus[turn.status] ?? turn.status}</span>
            {turn.modelSlug ? <span className="font-mono">{turn.modelSlug}</span> : null}
            <span>{relativeTime(turn.startedAt)}</span>
            {turn.commitBefore ? <span className="font-mono">{turn.commitBefore.slice(0, 7)}</span> : null}
            {turn.commitAfter ? <span className="font-mono">→ {turn.commitAfter.slice(0, 7)}</span> : null}
          </p>
          {turn.error ? <p className="text-destructive text-xs">{turn.error}</p> : null}
        </div>
      </div>
      {files.length ? (
        <Collapsible>
          <CollapsibleTrigger className="text-muted-foreground hover:text-foreground mt-1 flex items-center gap-1 text-xs [&[data-state=open]>svg]:rotate-90">
            <ChevronRight className="size-3 transition-transform" /> {t.fileChanges(files.length)}
          </CollapsibleTrigger>
          <CollapsibleContent className="mt-2 flex flex-col gap-2">
            {files.map((f) => (
              <CodeDiff key={f.path} filename={f.path} lines={f.lines} additions={f.additions} deletions={f.deletions} className="max-w-none" />
            ))}
          </CollapsibleContent>
        </Collapsible>
      ) : null}
    </div>
  );
}

/** The turn's diff (all files in one unified diff) → one CodeDiff per file. */
export function splitDiff(diff: string) {
  const out: { path: string; lines: ReturnType<typeof parseDiff>["lines"]; additions: number; deletions: number }[] = [];
  const chunks = diff.split(/^diff --git /m).filter(Boolean);
  for (const chunk of chunks) {
    const m = /^a\/(.+?) b\//.exec(chunk);
    const path = m?.[1] ?? "?";
    const body = chunk.slice(chunk.indexOf("\n") + 1);
    out.push({ path, ...parseDiff(body) });
  }
  return out;
}

function RestoreDialog({ turn, threadId, onClose }: { turn: Turn | null; threadId: string; onClose: () => void }) {
  const [proposal, setProposal] = useState<RestoreProposal | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [mode, setMode] = useState<"restore_tree" | "reset_hard">("restore_tree");
  const restore = useRestoreFiles(threadId);
  const [loadedFor, setLoadedFor] = useState<string | null>(null);

  if (turn && loadedFor !== turn.id) {
    setLoadedFor(turn.id);
    setProposal(null);
    setError(null);
    fetchRestoreProposal(turn.id).then(setProposal, (e: Error) => setError(e.message));
  }

  async function confirm() {
    if (!turn) return;
    try {
      const result = await restore.mutateAsync({ turnId: turn.id, mode });
      toast.success(t.restored(result.head.slice(0, 7)));
      onClose();
    } catch (e) {
      toast.error((e as Error).message);
    }
  }

  return (
    <Dialog open={turn !== null} onOpenChange={(open) => (open ? null : onClose())}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{t.restoreTitle}</DialogTitle>
          <DialogDescription>{t.restoreHint}</DialogDescription>
        </DialogHeader>
        {error ? <p className="text-destructive text-sm">{error}</p> : null}
        {proposal ? (
          <div className="space-y-3 text-sm">
            <p>
              {t.restoreTo} <span className="font-mono">{proposal.commit.slice(0, 7)}</span>
              {proposal.laterTurns > 0 ? <span className="text-muted-foreground"> · {t.laterTurns(proposal.laterTurns)}</span> : null}
            </p>
            {proposal.dirtyNow ? <p className="text-amber-600 dark:text-amber-400">{t.dirtyNowSafety}</p> : null}
            {proposal.changedFiles.length ? (
              <ul className="max-h-40 overflow-y-auto font-mono text-xs">
                {proposal.changedFiles.map((f) => (
                  <li key={f}>{f}</li>
                ))}
              </ul>
            ) : (
              <p className="text-muted-foreground">{t.nothingToRestore}</p>
            )}
            <RadioGroup value={mode} onValueChange={(v) => setMode(v as typeof mode)} className="gap-1">
              <div className="flex items-center gap-2">
                <RadioGroupItem value="restore_tree" id="restore-tree" />
                <Label htmlFor="restore-tree">{t.restoreTree}</Label>
              </div>
              <div className="flex items-center gap-2">
                <RadioGroupItem value="reset_hard" id="reset-hard" />
                <Label htmlFor="reset-hard">{t.resetHard}</Label>
              </div>
            </RadioGroup>
            <p className="text-muted-foreground text-xs">{t.restoreScope}</p>
          </div>
        ) : error ? null : (
          <Skeleton className="h-16 w-full" />
        )}
        <DialogFooter className="gap-2">
          <Button variant="ghost" onClick={onClose}>
            {t.cancel}
          </Button>
          <Button onClick={confirm} disabled={!proposal || restore.isPending}>
            {t.restoreFiles}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
