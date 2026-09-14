// Settings → 记忆: the global memory — the pipeline's switch and last run,
// MEMORY.md in the editor, the notes inbox with where each came from, a
// search over both.
import { Play, Search, Trash2 } from "lucide-react";
import { useEffect, useState } from "react";
import { toast } from "sonner";
import { useMemoryActions, useMemoryIndex, useMemoryNotes, useMemorySearch, useMemoryStatus, type MemoryNote } from "@/core/ai";
import { relativeTime } from "@/core/format";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/ui/components/ui/alert-dialog";
import { Badge } from "@/ui/components/ui/badge";
import { Button } from "@/ui/components/ui/button";
import { Input } from "@/ui/components/ui/input";
import { Label } from "@/ui/components/ui/label";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { Switch } from "@/ui/components/ui/switch";
import { CodeEditor } from "@/ui/editor/CodeEditor";
import { t } from "@/ui/strings";

const s = t.memoryPage;
const fail = (e: unknown) => toast.error(e instanceof Error ? e.message : String(e));

export function MemorySection() {
  const index = useMemoryIndex();
  const notes = useMemoryNotes();
  if (index.isPending || notes.isPending) return <Skeleton className="h-24 w-full" />;
  if (index.isError) return <p className="text-destructive text-sm">{index.error.message}</p>;
  if (notes.isError) return <p className="text-destructive text-sm">{notes.error.message}</p>;
  return (
    <div className="flex flex-col gap-8" data-testid="section-memory">
      <p className="text-muted-foreground text-sm">{s.hint}</p>
      <Pipeline />
      <SearchBox />
      <IndexEditor text={index.data} />
      <Notes notes={notes.data} />
    </div>
  );
}

function Pipeline() {
  const status = useMemoryStatus();
  const actions = useMemoryActions();
  if (!status.data) return null;
  const st = status.data;
  return (
    <section className="flex flex-col gap-3 rounded-lg border p-3">
      <h2 className="text-base font-medium">{s.pipeline}</h2>
      <div className="flex items-center justify-between gap-4">
        <Label htmlFor="mem-auto">{s.autoExtract}</Label>
        <Switch id="mem-auto" checked={st.autoExtract} onCheckedChange={(v) => actions.setAutoExtract.mutate(v, { onError: fail })} />
      </div>
      <div className="text-muted-foreground flex flex-wrap items-center gap-x-3 gap-y-1 text-xs">
        <span>{s.pending(st.pending)}</span>
        <span>{st.lastRunAt ? s.lastRun(relativeTime(st.lastRunAt)) : s.neverRan}</span>
        {st.lastError ? (
          <span className="text-destructive">
            {s.lastError}
            {st.lastError}
          </span>
        ) : null}
        <Button size="sm" variant="outline" className="ml-auto h-7" disabled={actions.run.isPending} onClick={() => actions.run.mutate(undefined, { onSuccess: () => toast.success(s.runStarted), onError: fail })}>
          <Play className="size-3.5" /> {s.runNow}
        </Button>
      </div>
    </section>
  );
}

function SearchBox() {
  const [draft, setDraft] = useState("");
  const [query, setQuery] = useState("");
  const hits = useMemorySearch(query);
  return (
    <section className="flex flex-col gap-2">
      <form
        className="flex gap-2"
        onSubmit={(e) => {
          e.preventDefault();
          setQuery(draft.trim());
        }}
      >
        <Input type="search" role="searchbox" aria-label={s.search} placeholder={s.searchHint} value={draft} onChange={(e) => setDraft(e.target.value)} className="min-w-0 flex-1" />
        <Button type="submit" variant="outline" aria-label={s.search}>
          <Search className="size-4" />
        </Button>
      </form>
      {query && hits.data ? (
        hits.data.length === 0 ? (
          <p className="text-muted-foreground text-sm">{s.noHits}</p>
        ) : (
          <ul className="divide-y rounded-lg border text-sm">
            {hits.data.map((h) => (
              <li key={`${h.file}:${h.line}`} className="flex gap-3 px-3 py-1.5">
                <span className="text-muted-foreground shrink-0 font-mono text-xs">
                  {h.file}:{h.line}
                </span>
                <span className="min-w-0 break-words">{h.text}</span>
              </li>
            ))}
          </ul>
        )
      ) : null}
    </section>
  );
}

function IndexEditor({ text }: { text: string }) {
  const actions = useMemoryActions();
  const [draft, setDraft] = useState(text);
  useEffect(() => setDraft(text), [text]);
  const dirty = draft !== text;
  const save = () => actions.writeIndex.mutate(draft, { onSuccess: () => toast.success(s.saved), onError: fail });
  return (
    <section className="flex flex-col gap-2">
      <div className="flex items-center justify-between gap-3">
        <h2 className="text-base font-medium">{s.index}</h2>
        <Button size="sm" disabled={!dirty || actions.writeIndex.isPending} onClick={save}>
          {s.saveIndex}
        </Button>
      </div>
      <div className="h-80 overflow-hidden rounded-lg border">
        <CodeEditor path="MEMORY.md" value={draft} onChange={setDraft} onSave={save} className="h-full" />
      </div>
    </section>
  );
}

function Notes({ notes }: { notes: MemoryNote[] }) {
  const actions = useMemoryActions();
  const [confirm, setConfirm] = useState<MemoryNote | null>(null);
  return (
    <section className="flex flex-col gap-2">
      <h2 className="text-base font-medium">{s.notes}</h2>
      {notes.length === 0 ? <p className="text-muted-foreground text-sm">{s.noNotes}</p> : null}
      <ul className="divide-y rounded-lg border">
        {notes.map((n) => (
          <li key={n.file} className="flex items-start gap-3 px-3 py-2 text-sm" data-testid={`note-${n.file}`}>
            <div className="min-w-0 flex-1">
              <p className="break-words">{n.text}</p>
              <p className="text-muted-foreground mt-0.5 flex flex-wrap items-center gap-2 text-xs">
                {n.project ? <span>{n.project}</span> : null}
                {n.at ? <span>{relativeTime(n.at)}</span> : null}
                {n.source === "auto" ? <Badge variant="outline">{s.auto}</Badge> : null}
              </p>
            </div>
            <Button variant="ghost" size="icon" className="size-7 shrink-0" aria-label={s.deleteNote} onClick={() => setConfirm(n)}>
              <Trash2 className="size-4" />
            </Button>
          </li>
        ))}
      </ul>
      <AlertDialog open={confirm !== null} onOpenChange={(o) => (o ? null : setConfirm(null))}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{s.deleteNoteTitle}</AlertDialogTitle>
            <AlertDialogDescription>{s.deleteNoteHint}</AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>{t.cancel}</AlertDialogCancel>
            <AlertDialogAction
              onClick={() => {
                if (confirm) actions.deleteNote.mutate(confirm.file, { onError: fail });
                setConfirm(null);
              }}
            >
              {t.delete}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </section>
  );
}
