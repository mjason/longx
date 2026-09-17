// Settings → 知识: the native kernel's knowledge — the person's global
// docs (edited here, each save a commit) and Longx's shipped ones (read).
import { Plus, Trash2, X } from "lucide-react";
import { useEffect, useState } from "react";
import { toast } from "sonner";
import { useKnowledgeActions, useKnowledgeDoc, useKnowledgeDocs, type KnowledgeDoc } from "@/core/ai";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/ui/components/ui/alert-dialog";
import { Badge } from "@/ui/components/ui/badge";
import { Button } from "@/ui/components/ui/button";
import { Input } from "@/ui/components/ui/input";
import { Label } from "@/ui/components/ui/label";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { CodeEditor } from "@/ui/editor/CodeEditor";
import { t } from "@/ui/strings";

const s = t.knowledgePage;
const fail = (e: unknown) => toast.error(e instanceof Error ? e.message : String(e));

export function KnowledgeSection() {
  const docs = useKnowledgeDocs();
  const [open, setOpen] = useState<{ path: string; writable: boolean } | null>(null);
  const [creating, setCreating] = useState(false);
  if (docs.isPending) return <Skeleton className="h-24 w-full" />;
  if (docs.isError) return <p className="text-destructive text-sm">{docs.error.message}</p>;
  const global = docs.data.filter((d) => d.root === "global");
  const shipped = docs.data.filter((d) => d.root === "longx");
  return (
    <div className="flex flex-col gap-6" data-testid="section-knowledge">
      <p className="text-muted-foreground text-sm">{s.hint}</p>
      {open ? (
        <Editor path={open.path} writable={open.writable} onClose={() => setOpen(null)} />
      ) : creating ? (
        <NewDoc onClose={() => setCreating(false)} onCreated={(path) => { setCreating(false); setOpen({ path, writable: true }); }} />
      ) : null}
      <DocList title={s.global} docs={global} empty={s.none} onOpen={setOpen} action={<Button size="sm" variant="outline" onClick={() => setCreating(true)}><Plus className="size-4" /> {s.create}</Button>} />
      <DocList title={s.shipped} docs={shipped} onOpen={setOpen} />
    </div>
  );
}

function DocList({ title, docs, empty, onOpen, action }: { title: string; docs: KnowledgeDoc[]; empty?: string; onOpen: (d: { path: string; writable: boolean }) => void; action?: React.ReactNode }) {
  return (
    <section className="space-y-2">
      <div className="flex items-center justify-between gap-2">
        <h3 className="text-sm font-medium">{title}</h3>
        {action}
      </div>
      {docs.length === 0 ? (
        <p className="text-muted-foreground text-sm">{empty}</p>
      ) : (
        <ul className="divide-y rounded-lg border">
          {docs.map((d) => (
            <li key={d.path}>
              <button type="button" className="hover:bg-accent/40 flex w-full flex-col gap-0.5 px-3 py-2 text-left" onClick={() => onOpen({ path: d.path, writable: d.writable })}>
                <span className="flex flex-wrap items-center gap-2">
                  <span className="text-sm font-medium">{d.title}</span>
                  {d.always ? <Badge variant="outline">{s.always}</Badge> : null}
                  <span className="text-muted-foreground min-w-0 truncate font-mono text-xs">{d.path}</span>
                </span>
                <span className="text-muted-foreground text-sm">{d.summary}</span>
              </button>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

function Editor({ path, writable, onClose }: { path: string; writable: boolean; onClose: () => void }) {
  const doc = useKnowledgeDoc(path);
  const actions = useKnowledgeActions();
  const [draft, setDraft] = useState<string | null>(null);
  const [confirm, setConfirm] = useState(false);
  useEffect(() => setDraft(null), [path]);
  if (doc.isPending) return <Skeleton className="h-40 w-full" />;
  if (doc.isError) return <p className="text-destructive text-sm">{doc.error.message}</p>;
  const value = draft ?? doc.data;
  const save = () =>
    actions.write.mutateAsync({ path, content: value }).then(() => { toast.success(s.saved); setDraft(null); }, fail);
  const remove = () =>
    actions.remove.mutateAsync(path).then(() => { toast.success(s.removed); setConfirm(false); onClose(); }, fail);
  return (
    <section className="space-y-2 rounded-lg border p-3" data-testid="knowledge-editor">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <span className="font-mono text-xs">{path}</span>
        <span className="flex items-center gap-2">
          {writable ? (
            <>
              <Button size="sm" onClick={save} disabled={draft === null || actions.write.isPending}>{s.save}</Button>
              <Button size="sm" variant="ghost" className="text-destructive" onClick={() => setConfirm(true)}><Trash2 className="size-4" /> {s.remove}</Button>
            </>
          ) : (
            <span className="text-muted-foreground text-xs">{s.readOnly}</span>
          )}
          <Button size="sm" variant="ghost" onClick={onClose} aria-label={s.close}><X className="size-4" /></Button>
        </span>
      </div>
      <div className="h-80">
        <CodeEditor path={path} value={value} onChange={setDraft} onSave={writable ? save : undefined} readOnly={!writable} wrap className="h-full" />
      </div>
      <AlertDialog open={confirm} onOpenChange={setConfirm}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{s.confirmRemove(path)}</AlertDialogTitle>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>{t.cancel}</AlertDialogCancel>
            <AlertDialogAction onClick={remove}>{s.remove}</AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </section>
  );
}

function NewDoc({ onClose, onCreated }: { onClose: () => void; onCreated: (path: string) => void }) {
  const actions = useKnowledgeActions();
  const [name, setName] = useState("");
  const clean = name.trim().replace(/\.md$/, "");
  const inTopic = clean.split("/").filter(Boolean).length >= 2;
  const create = () => {
    const path = `global/${clean}.md`;
    actions.write.mutateAsync({ path, content: s.template(clean.split("/").pop() ?? clean) }).then(() => onCreated(path), fail);
  };
  return (
    <section className="flex flex-wrap items-end gap-2 rounded-lg border p-3" data-testid="knowledge-new">
      <div className="flex flex-col gap-1.5">
        <Label htmlFor="knowledge-new-path">{s.newPath}</Label>
        <Input id="knowledge-new-path" value={name} onChange={(e) => setName(e.target.value)} placeholder="tools/deploy" className="w-64 font-mono" autoFocus />
        <span className="text-muted-foreground text-xs">{clean && !inTopic ? s.needsTopic : s.newPathHint}</span>
      </div>
      <Button size="sm" onClick={create} disabled={!clean || !inTopic || actions.write.isPending}>{s.create}</Button>
      <Button size="sm" variant="ghost" onClick={onClose}>{t.cancel}</Button>
    </section>
  );
}
