import { AlertCircle, CheckCircle2, ChevronRight, Loader2, RotateCcw, Undo2, XCircle } from "lucide-react";
import { useState } from "react";
import { useNavigate, useParams } from "react-router";
import { toast } from "sonner";
import { relativeTime } from "@/core/format";
import { fetchRestoreProposal, useModels, useRedoTurn, useRestoreFiles, useTurns, type RestoreProposal } from "@/core/projects";
import { parseDiff } from "@/ui/chat/toolkit";
import { CodeDiff } from "@/ui/components/assistant-ui/elements/code-diff";
import { Button } from "@/ui/components/ui/button";
import { Checkbox } from "@/ui/components/ui/checkbox";
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from "@/ui/components/ui/collapsible";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/ui/components/ui/dialog";
import { Label } from "@/ui/components/ui/label";
import { RadioGroup, RadioGroupItem } from "@/ui/components/ui/radio-group";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/ui/components/ui/select";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { Textarea } from "@/ui/components/ui/textarea";
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
 * bookmarks — what each one changed, going back to before one, and running
 * one again with other text or another model.
 */
export function TurnsTool({ ctx }: { ctx: ProjectContext }) {
  const { threadId } = useParams();
  const turns = useTurns(threadId);
  const [restoring, setRestoring] = useState<Turn | null>(null);
  const [redoing, setRedoing] = useState<Turn | null>(null);

  if (!threadId) return <p className="text-muted-foreground text-sm">{t.pickThread}</p>;
  if (turns.isPending) return <Skeleton className="h-16 w-full" />;
  if (turns.isError) return <p className="text-destructive text-sm">{turns.error.message}</p>;

  return (
    <div className="flex flex-col gap-2" data-testid="turns-tool">
      {turns.data.length === 0 ? <p className="text-muted-foreground text-sm">{t.noTurns}</p> : null}
      {turns.data.map((turn, i) => (
        <TurnRow key={turn.id} turn={turn} index={i + 1} onRestore={() => setRestoring(turn)} onRedo={() => setRedoing(turn)} />
      ))}
      <RestoreDialog turn={restoring} threadId={threadId} onClose={() => setRestoring(null)} />
      <RedoDialog turn={redoing} threadId={threadId} slug={ctx.slug} onClose={() => setRedoing(null)} />
    </div>
  );
}

function TurnRow({ turn, index, onRestore, onRedo }: { turn: Turn; index: number; onRestore: () => void; onRedo: () => void }) {
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
      {turn.status !== "reverted" && turn.status !== "in_progress" ? (
        <div className="mt-2 flex gap-1">
          {turn.commitBefore ? (
            <Button variant="ghost" size="sm" className="h-7 px-2 text-xs" onClick={onRestore}>
              <Undo2 /> {t.restoreBefore}
            </Button>
          ) : null}
          <Button variant="ghost" size="sm" className="h-7 px-2 text-xs" onClick={onRedo}>
            <RotateCcw /> {t.redo}
          </Button>
        </div>
      ) : null}
    </div>
  );
}

/** codex's per-turn diff (all files in one unified diff) → one CodeDiff per file. */
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

function RedoDialog({ turn, threadId, slug, onClose }: { turn: Turn | null; threadId: string; slug: string; onClose: () => void }) {
  const [text, setText] = useState("");
  const [model, setModel] = useState<string>("__same");
  const [mode, setMode] = useState<"revert" | "fork">("revert");
  const [restoreFirst, setRestoreFirst] = useState(false);
  const [openedFor, setOpenedFor] = useState<string | null>(null);
  const models = useModels();
  const redo = useRedoTurn(threadId);
  const navigate = useNavigate();

  if (turn && openedFor !== turn.id) {
    setOpenedFor(turn.id);
    setText(turn.userText ?? "");
    setModel("__same");
    setMode("revert");
    setRestoreFirst(false);
  }

  async function submit() {
    if (!turn) return;
    try {
      const result = await redo.mutateAsync({ turnId: turn.id, text, mode, restoreFiles: restoreFirst, ...(model !== "__same" ? { model } : {}) });
      onClose();
      if (result.threadId !== threadId) navigate(`/p/${slug}/t/${result.threadId}`);
    } catch (e) {
      toast.error((e as Error).message);
    }
  }

  return (
    <Dialog open={turn !== null} onOpenChange={(open) => (open ? null : onClose())}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{t.redoTitle}</DialogTitle>
          <DialogDescription>{t.redoHint}</DialogDescription>
        </DialogHeader>
        <div className="space-y-3">
          <Textarea value={text} onChange={(e) => setText(e.target.value)} aria-label={t.redoText} rows={3} />
          <div className="flex items-center gap-2">
            <Label className="w-16 shrink-0">{t.model}</Label>
            <Select value={model} onValueChange={setModel}>
              <SelectTrigger className="font-mono text-xs" aria-label={t.model}>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="__same" className="font-mono text-xs">
                  {turn?.modelSlug ?? t.defaultModel} · {t.sameModel}
                </SelectItem>
                {(models.data ?? [])
                  .filter((m) => m.slug)
                  .map((m) => (
                    <SelectItem key={m.id} value={m.slug!} className="font-mono text-xs">
                      {m.slug}
                    </SelectItem>
                  ))}
              </SelectContent>
            </Select>
          </div>
          <RadioGroup value={mode} onValueChange={(v) => setMode(v as typeof mode)} className="gap-1">
            <div className="flex items-center gap-2">
              <RadioGroupItem value="revert" id="redo-revert" />
              <Label htmlFor="redo-revert">{t.redoRevert}</Label>
            </div>
            <div className="flex items-center gap-2">
              <RadioGroupItem value="fork" id="redo-fork" />
              <Label htmlFor="redo-fork">{t.redoFork}</Label>
            </div>
          </RadioGroup>
          {turn?.commitBefore ? (
            <div className="flex items-center gap-2">
              <Checkbox id="redo-restore" checked={restoreFirst} onCheckedChange={(v) => setRestoreFirst(v === true)} />
              <Label htmlFor="redo-restore">{t.redoRestoreFirst}</Label>
            </div>
          ) : null}
        </div>
        <DialogFooter className="gap-2">
          <Button variant="ghost" onClick={onClose}>
            {t.cancel}
          </Button>
          <Button onClick={submit} disabled={redo.isPending || !text.trim()}>
            {t.redoRun}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
