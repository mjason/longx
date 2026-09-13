import type { DirtyChange, DirtyDecision } from "@/core/chat/adapter";
import { Button } from "@/ui/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/ui/components/ui/dialog";
import { t } from "@/ui/strings";

export type DirtyPrompt = { changes: DirtyChange[]; resolve: (decision: DirtyDecision) => void };

/** The project's dirty_start is "ask": commit first, ignore, or don't send. */
export function DirtyTreeDialog({ prompt }: { prompt: DirtyPrompt | null }) {
  const shown = prompt?.changes.slice(0, 8) ?? [];
  const more = (prompt?.changes.length ?? 0) - shown.length;
  return (
    <Dialog open={prompt !== null} onOpenChange={(open) => (open ? null : prompt?.resolve(null))}>
      <DialogContent data-testid="dirty-tree-dialog">
        <DialogHeader>
          <DialogTitle>{t.dirtyTreeTitle}</DialogTitle>
          <DialogDescription>{t.dirtyTreeHint}</DialogDescription>
        </DialogHeader>
        <ul className="max-h-48 overflow-y-auto font-mono text-xs">
          {shown.map((c) => (
            <li key={c.path} className="truncate">
              <span className="text-muted-foreground mr-2">{c.status}</span>
              {c.path}
            </li>
          ))}
          {more > 0 ? <li className="text-muted-foreground">{t.moreFiles(more)}</li> : null}
        </ul>
        <DialogFooter className="gap-2">
          <Button variant="ghost" onClick={() => prompt?.resolve(null)}>
            {t.cancel}
          </Button>
          <Button variant="outline" onClick={() => prompt?.resolve("ignore")}>
            {t.dirtyIgnore}
          </Button>
          <Button onClick={() => prompt?.resolve("commit")}>{t.dirtyCommit}</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
