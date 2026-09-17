// Settings → Agent 内核: the native kernel's team parameters (the topmost
// layer of every agent's description) and the person's global agent files.
import { Plus, Trash2, X } from "lucide-react";
import { useEffect, useState } from "react";
import { toast } from "sonner";
import { useAgentFile, useAgentFileActions, useAgentFiles, useAgentSettings, useAgentSettingsActions, usePublicUrl, usePublicUrlActions } from "@/core/agent";
import { useModelRows } from "@/core/ai";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/ui/components/ui/alert-dialog";
import { Button } from "@/ui/components/ui/button";
import { Input } from "@/ui/components/ui/input";
import { Label } from "@/ui/components/ui/label";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { AgentSettingsFields, agentSettingsForm, agentSettingsInput, type AgentSettingsForm } from "@/ui/components/AgentSettingsFields";
import { CodeEditor } from "@/ui/editor/CodeEditor";
import { t } from "@/ui/strings";

const s = t.agentKernel;
const fail = (e: unknown) => toast.error(e instanceof Error ? e.message : String(e));

export function AgentKernelSection() {
  return (
    <div className="flex flex-col gap-8" data-testid="section-agent">
      <p className="text-muted-foreground text-sm">{s.hint}</p>
      <SettingsCard />
      <PublicUrlCard />
      <FilesCard />
    </div>
  );
}

function SettingsCard() {
  const settings = useAgentSettings();
  const models = useModelRows();
  if (settings.isPending || models.isPending) return <Skeleton className="h-24 w-full" />;
  if (settings.isError) return <p className="text-destructive text-sm">{settings.error.message}</p>;
  return <SettingsForm key={JSON.stringify(settings.data)} initial={agentSettingsForm(settings.data)} models={models.data ?? []} />;
}

function SettingsForm({ initial, models }: { initial: AgentSettingsForm; models: ReturnType<typeof useModelRows>["data"] & object }) {
  const actions = useAgentSettingsActions();
  const [form, setForm] = useState(initial);
  const save = () => actions.save.mutateAsync(agentSettingsInput(form)).then(() => toast.success(s.saved), fail);
  return (
    <section className="space-y-4 rounded-lg border p-4" data-testid="agent-settings">
      <AgentSettingsFields idPrefix="ak" value={form} onChange={setForm} models={models} />
      <Button size="sm" onClick={save} disabled={actions.save.isPending}>{s.save}</Button>
    </section>
  );
}

function PublicUrlCard() {
  const current = usePublicUrl();
  const actions = usePublicUrlActions();
  const [draft, setDraft] = useState<string | null>(null);
  if (current.isPending) return <Skeleton className="h-16 w-full" />;
  if (current.isError) return <p className="text-destructive text-sm">{current.error.message}</p>;
  const value = draft ?? current.data.setting ?? "";
  const save = () => actions.save.mutateAsync(value).then(() => { toast.success(s.publicUrlSaved); setDraft(null); }, fail);
  return (
    <section className="space-y-2 rounded-lg border p-4" data-testid="public-url">
      <Label htmlFor="ak-public-url">{s.publicUrl}</Label>
      <div className="flex flex-wrap gap-2">
        <Input id="ak-public-url" value={value} placeholder={current.data.url} onChange={(e) => setDraft(e.target.value)} className="w-80 font-mono" />
        <Button size="sm" onClick={save} disabled={draft === null || actions.save.isPending}>{s.save}</Button>
      </div>
      <p className="text-muted-foreground text-xs">{s.publicUrlHint(current.data.url)}</p>
    </section>
  );
}

function FilesCard() {
  const files = useAgentFiles();
  const [open, setOpen] = useState<string | null>(null);
  const [creating, setCreating] = useState(false);
  if (files.isPending) return <Skeleton className="h-24 w-full" />;
  if (files.isError) return <p className="text-destructive text-sm">{files.error.message}</p>;
  return (
    <section className="space-y-3" data-testid="agent-files">
      <div className="flex items-center justify-between gap-2">
        <div>
          <h2 className="text-base font-medium">{s.files}</h2>
          <p className="text-muted-foreground text-xs">{s.filesHint}</p>
        </div>
        <Button size="sm" variant="outline" onClick={() => setCreating(true)}><Plus className="size-4" /> {s.newFile}</Button>
      </div>
      {open ? (
        <Editor path={open} onClose={() => setOpen(null)} />
      ) : creating ? (
        <NewFile onClose={() => setCreating(false)} onCreated={(path) => { setCreating(false); setOpen(path); }} />
      ) : null}
      {files.data.length === 0 ? (
        <p className="text-muted-foreground text-sm">{s.noFiles}</p>
      ) : (
        <ul className="divide-y rounded-lg border">
          {files.data.map((f) => (
            <li key={f.path}>
              <button type="button" className="hover:bg-accent/40 flex w-full items-center justify-between px-3 py-2 text-left font-mono text-xs" onClick={() => setOpen(f.path)}>
                <span>{f.path}</span>
                <span className="text-muted-foreground">{f.size} B</span>
              </button>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

function Editor({ path, onClose }: { path: string; onClose: () => void }) {
  const file = useAgentFile(path);
  const actions = useAgentFileActions();
  const [draft, setDraft] = useState<string | null>(null);
  const [confirm, setConfirm] = useState(false);
  useEffect(() => setDraft(null), [path]);
  if (file.isPending) return <Skeleton className="h-40 w-full" />;
  if (file.isError) return <p className="text-destructive text-sm">{file.error.message}</p>;
  const value = draft ?? file.data;
  const save = () => actions.write.mutateAsync({ path, content: value }).then(() => { toast.success(s.saved); setDraft(null); }, fail);
  const remove = () => actions.remove.mutateAsync(path).then(() => { toast.success(s.removed); setConfirm(false); onClose(); }, fail);
  return (
    <section className="space-y-2 rounded-lg border p-3" data-testid="agent-file-editor">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <span className="font-mono text-xs">{path}</span>
        <span className="flex items-center gap-2">
          <Button size="sm" onClick={save} disabled={draft === null || actions.write.isPending}>{s.save}</Button>
          <Button size="sm" variant="ghost" className="text-destructive" onClick={() => setConfirm(true)}><Trash2 className="size-4" /> {s.remove}</Button>
          <Button size="sm" variant="ghost" onClick={onClose} aria-label={s.close}><X className="size-4" /></Button>
        </span>
      </div>
      <div className="h-80">
        <CodeEditor path={path} value={value} onChange={setDraft} onSave={save} wrap className="h-full" />
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

function NewFile({ onClose, onCreated }: { onClose: () => void; onCreated: (path: string) => void }) {
  const actions = useAgentFileActions();
  const [path, setPath] = useState("");
  const clean = path.trim().replace(/^\/+/, "");
  const valid = /\.(exs|md)$/.test(clean) && !clean.includes("..");
  const template = () => {
    const parts = clean.split("/");
    if (parts[0] === "agents" && parts.length === 3 && parts[2] === "agent.exs") return s.templateAgent(parts[1] ?? "");
    if (parts[0] === "plugs" && clean.endsWith(".exs")) {
      const stem = (parts[parts.length - 1] ?? "").replace(/\.exs$/, "");
      return s.templatePlug(stem.replace(/(^|[-_])(\w)/g, (_, __, c: string) => c.toUpperCase()));
    }
    return "";
  };
  const create = () => actions.write.mutateAsync({ path: clean, content: template() }).then(() => onCreated(clean), fail);
  return (
    <section className="flex flex-wrap items-end gap-2 rounded-lg border p-3" data-testid="agent-file-new">
      <div className="flex flex-col gap-1.5">
        <Label htmlFor="agent-new-path">{s.newPath}</Label>
        <Input id="agent-new-path" value={path} onChange={(e) => setPath(e.target.value)} placeholder="agents/writer/agent.exs" className="w-72 font-mono" autoFocus />
        <span className="text-muted-foreground text-xs">{s.newPathHint}</span>
      </div>
      <Button size="sm" onClick={create} disabled={!valid || actions.write.isPending}>{t.knowledgePage.create}</Button>
      <Button size="sm" variant="ghost" onClick={onClose}>{t.cancel}</Button>
    </section>
  );
}
