import { useState } from "react";
import { useExtensions, useExtensionFiles, type ExtensionItem } from "@/core/agent";
import { useAgentDefinition } from "@/core/projects";
import { useFrame } from "@/core/frame";
import { useWorkbench } from "@/core/workbench";
import { requestIntent } from "@/core/keys/intents";
import { Badge } from "@/ui/components/ui/badge";
import { Button } from "@/ui/components/ui/button";
import { Input } from "@/ui/components/ui/input";
import { Dialog, DialogBody, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/ui/components/ui/dialog";
import { PromotionDialog } from "./PromotionDialog";
import { useSettingsCopy } from "./copy";

type Tab = "overview" | ExtensionItem["kind"];
const tabs: Tab[] = ["overview", "definition", "agents", "plugs", "watches", "knowledge", "artifacts"];
const PAGE_SIZE = 30;

export function ProjectExtensions({ projectId }: { projectId: string }) {
  const s = useSettingsCopy();
  const inventory = useExtensions(projectId);
  const definition = useAgentDefinition(projectId);
  const frame = useFrame();
  const workbench = useWorkbench(projectId);
  const [tab, setTab] = useState<Tab>("overview");
  const [layer, setLayer] = useState("all");
  const [query, setQuery] = useState("");
  const [page, setPage] = useState(0);
  const [sharing, setSharing] = useState<string | null>(null);
  const [directory, setDirectory] = useState<string | null>(null);
  const reveal = (path: string) => { frame.open("files"); requestIntent("files.reveal", path); };
  const openFile = (path: string) => workbench.open({ kind: "file", path });
  const data = inventory.data ?? [];
  const visible = data.filter((item) => item.kind === tab && (layer === "all" || item.layer === layer) &&
    `${item.name} ${item.path}`.toLowerCase().includes(query.toLowerCase()));
  const changeTab = (next: Tab) => { setTab(next); setPage(0); setQuery(""); setLayer("all"); };
  return (
    <section className="space-y-4" data-testid="project-extensions">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div><h2 className="text-lg font-medium">{s.extensions}</h2><p className="text-muted-foreground text-xs">{s.extensionHint}</p></div>
        <Button size="sm" variant="outline" onClick={() => reveal(".longx")}>{s.openDirectory}</Button>
      </div>
      <div role="tablist" aria-label={s.extensions} className="flex overflow-x-auto border-b">
        {tabs.map((key) => <button key={key} type="button" role="tab" aria-selected={tab === key}
          className={`shrink-0 border-b-2 px-3 py-2 text-sm ${tab === key ? "border-primary text-primary" : "border-transparent text-muted-foreground"}`}
          onClick={() => changeTab(key)}>{s.tabs[key]}{key !== "overview" ? ` (${data.filter((item) => item.kind === key).length})` : ""}</button>)}
      </div>
      {inventory.isPending ? <p>{s.loading}</p> : null}
      {inventory.isError ? <p role="alert" className="text-destructive">{inventory.error.message}</p> : null}
      {tab === "overview" ? <>
        <div className="grid gap-3 sm:grid-cols-2">
          {tabs.filter((key) => key !== "overview").map((key) => <button type="button" key={key} onClick={() => changeTab(key)} className="rounded-lg border p-4 text-left hover:bg-accent/30">
            <span className="font-medium">{s.tabs[key]}</span><span className="text-muted-foreground ml-2 text-sm">{data.filter((item) => item.kind === key).length}</span>
          </button>)}
        </div>
      </> : <>
        <div className="flex flex-wrap items-center gap-2">
          <Input aria-label={s.findExtension} placeholder={s.findExtension} value={query} onChange={(e) => { setQuery(e.target.value); setPage(0); }} className="w-full sm:w-64" />
          {([["all", s.allSources], ["local", s.local], ["shared", s.shared]] as const).map(([value, label]) =>
            <Button size="sm" key={value} variant={layer === value ? "secondary" : "ghost"} onClick={() => { setLayer(value); setPage(0); }}>{label}</Button>)}
        </div>
        {tab === "definition" ? <p className="text-muted-foreground text-xs">{s.definitionHint}</p> : null}
        {tab === "artifacts" ? <p className="text-muted-foreground text-xs">{s.artifactHint}</p> : null}
        <ul className="divide-y rounded-lg border">
          {visible.slice(page * PAGE_SIZE, (page + 1) * PAGE_SIZE).map((item) => {
            const loadedRole = definition.data?.agents.some((a) => a.name === item.name && (a.layer === "local" ? "local" : "shared") === item.layer);
            const status = !item.complete ? s.incomplete : item.kind === "agents" && loadedRole ? s.loadedRole :
              item.layer === "shared" && !definition.data?.trusted && ["agents", "plugs", "watches"].includes(item.kind) ? s.untrusted : s.discovered;
            return <li key={item.path} className="flex flex-wrap items-start gap-3 px-4 py-3" data-testid="extension-row">
              <div className="min-w-0 flex-1"><p className="break-all text-sm font-medium">{item.name}</p><p className="text-muted-foreground break-all font-mono text-xs">{item.path}</p>
                <div className="mt-2 flex flex-wrap gap-2"><Badge variant="outline">{item.layer}</Badge>{item.kind !== "artifacts" ? <span className={`text-xs ${!item.complete ? "text-destructive" : "text-muted-foreground"}`}>{status}</span> : null}</div>
              </div>
              <div className="flex gap-2">
                <Button size="sm" variant="outline" onClick={() => item.kind === "agents" || item.kind === "artifacts" ? setDirectory(item.path) : openFile(item.path)}>{item.kind === "artifacts" ? s.viewFiles : s.view}</Button>
                {item.shareable && item.complete ? <Button size="sm" variant="outline" onClick={() => setSharing(item.path.replace(".longx/local/", ""))}>{s.prepareShare}</Button> : null}
              </div>
            </li>;
          })}
        </ul>
        {!visible.length && !inventory.isPending ? <p className="text-muted-foreground text-sm">{s.noObjects}</p> : null}
        {visible.length > PAGE_SIZE ? <div className="flex justify-end gap-2">
          <Button size="sm" variant="outline" disabled={page === 0} onClick={() => setPage(page - 1)}>{s.previous}</Button>
          <Button size="sm" variant="outline" disabled={(page + 1) * PAGE_SIZE >= visible.length} onClick={() => setPage(page + 1)}>{s.next}</Button>
        </div> : null}
      </>}
      <PromotionDialog projectId={projectId} path={sharing} onClose={() => setSharing(null)} />
      <ExtensionFiles projectId={projectId} path={directory} onClose={() => setDirectory(null)} onOpenFile={openFile} />
    </section>
  );
}

function ExtensionFiles({ projectId, path, onClose, onOpenFile }: { projectId: string; path: string | null; onClose: () => void; onOpenFile: (path: string) => void }) {
  const s = useSettingsCopy();
  const [inside, setInside] = useState<string | null>(null);
  const current = inside && path && inside.startsWith(path + "/") ? inside : path;
  const files = useExtensionFiles(projectId, current);
  return <Dialog open={path !== null} onOpenChange={(open) => { if (!open) { setInside(null); onClose(); } }}>
    <DialogContent><DialogHeader><DialogTitle>{s.viewFiles}</DialogTitle><DialogDescription className="break-all font-mono">{current}</DialogDescription></DialogHeader>
      <DialogBody className="space-y-3">
        {path?.startsWith(".longx/local/artifacts/") ? <p className="text-muted-foreground text-xs">{s.artifactSafety}</p> : null}
        {current !== path ? <Button size="sm" variant="outline" onClick={() => setInside(current ? current.slice(0, current.lastIndexOf("/")) : null)}>← {s.previous}</Button> : null}
        {files.isPending ? <p>{s.loading}</p> : null}
        {files.isError ? <p role="alert" className="text-destructive">{files.error.message}</p> : null}
        {files.data?.map((file) => <button key={file.path} type="button" className="flex w-full items-center justify-between gap-2 border-b py-2 text-left text-xs" onClick={() => {
          if (file.kind === "dir") setInside(file.path); else { onOpenFile(file.path); onClose(); }
        }}><span className="break-all font-mono">{file.kind === "dir" ? "▸ " : ""}{file.name}</span><span className="shrink-0 text-muted-foreground">{file.kind === "file" ? `${file.size} ${s.bytes}` : ""}</span></button>)}
      </DialogBody>
    </DialogContent>
  </Dialog>;
}
