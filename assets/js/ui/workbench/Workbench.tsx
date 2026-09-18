// The centre of the project window as an editor area: a tab strip — the
// chat first and always, then the files and diffs opened from the tools —
// over whichever is active. The chat stays mounted behind a file so its
// scroll and composer draft survive a look at the code.
import { AppWindow, FileCode2, GitCompareArrows, MessagesSquare, X } from "lucide-react";
import { useState, type ReactNode } from "react";
import { useViewport } from "@/core/viewport";
import { tabKey, useWorkbench, type Tab } from "@/core/workbench";
import { Sheet, SheetContent, SheetHeader, SheetTitle } from "@/ui/components/ui/sheet";
import { AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle } from "@/ui/components/ui/alert-dialog";
import { t } from "@/ui/strings";
import { DiffTab } from "./DiffTab";
import { EditorTab } from "./EditorTab";

export function Workbench({ projectId, children }: { projectId: string; children: ReactNode }) {
  const wb = useWorkbench(projectId);
  const viewport = useViewport();
  const active = wb.tabs.find((tab) => tabKey(tab) === wb.active) ?? wb.tabs[0]!;
  // a phone has no room for a tab strip around an artifact: a full-screen sheet over the chat
  const phoneArtifact = viewport === "phone" && active.kind === "artifact" ? active : null;
  // closing a tab with unsaved edits asks first
  const [closing, setClosing] = useState<Tab | null>(null);
  const close = (tab: Tab) => (wb.dirty.includes(tabKey(tab)) ? setClosing(tab) : wb.close(tabKey(tab)));

  return (
    <div className="flex min-h-0 flex-1 flex-col" data-testid="workbench">
      {wb.tabs.length > 1 ? (
        <div role="tablist" aria-label="工作区" className="bg-sidebar border-sidebar-border flex h-9 shrink-0 items-stretch overflow-x-auto border-b" data-testid="workbench-tabs">
          {wb.tabs.map((tab) => {
            const key = tabKey(tab);
            const isActive = key === wb.active;
            return (
              <div
                key={key}
                role="tab"
                aria-selected={isActive}
                className={`group flex shrink-0 items-center gap-1.5 border-r px-3 text-xs ${isActive ? "bg-background text-foreground" : "text-muted-foreground hover:text-foreground"}`}
              >
                <button type="button" className="flex h-full items-center gap-1.5" onClick={() => wb.activate(key)}>
                  <TabIcon tab={tab} />
                  <span className="max-w-48 truncate font-mono">{tabLabel(tab)}</span>
                  {wb.dirty.includes(key) ? <span className="text-warning" title={t.unsavedChanges}>●</span> : null}
                </button>
                {tab.kind !== "chat" ? (
                  <button type="button" aria-label={`${t.closeTab} ${tabLabel(tab)}`} className="text-muted-foreground hover:text-foreground rounded p-0.5" onClick={() => close(tab)}>
                    <X className="size-3" />
                  </button>
                ) : null}
              </div>
            );
          })}
        </div>
      ) : null}
      <div className={`min-h-0 flex-1 flex-col ${active.kind === "chat" ? "flex" : "hidden"}`}>{children}</div>
      {active.kind === "file" ? <EditorTab key={active.path} projectId={projectId} path={active.path} line={active.line} /> : null}
      {active.kind === "diff" ? <DiffTab key={tabKey(active)} projectId={projectId} path={active.path} sha={active.sha} /> : null}
      {active.kind === "artifact" && !phoneArtifact ? <ArtifactTab key={tabKey(active)} tab={active} /> : null}
      <Sheet open={phoneArtifact !== null} onOpenChange={(open) => (open || !phoneArtifact ? null : wb.close(tabKey(phoneArtifact)))}>
        <SheetContent side="bottom" showCloseButton={false} className="flex h-dvh flex-col gap-0 rounded-none p-0" data-testid="artifact-sheet">
          <SheetHeader className="safe-top border-border/60 flex flex-row items-center gap-2 border-b px-4 py-3">
            <SheetTitle className="min-w-0 flex-1 truncate text-sm">{phoneArtifact?.title ?? ""}</SheetTitle>
            <button type="button" aria-label={t.close} className="touch-target text-muted-foreground hover:text-foreground flex items-center justify-center rounded-md" onClick={() => phoneArtifact && wb.close(tabKey(phoneArtifact))}>
              <X className="size-4" />
            </button>
          </SheetHeader>
          {phoneArtifact ? <ArtifactTab tab={phoneArtifact} /> : null}
        </SheetContent>
      </Sheet>
      <AlertDialog open={closing !== null} onOpenChange={(open) => (open ? null : setClosing(null))}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{closing ? t.closeDirtyTitle(tabLabel(closing)) : ""}</AlertDialogTitle>
            <AlertDialogDescription>{t.closeDirtyHint}</AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>{t.cancel}</AlertDialogCancel>
            <AlertDialogAction
              className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
              onClick={() => {
                if (closing) wb.close(tabKey(closing));
                setClosing(null);
              }}
            >
              {t.closeWithoutSaving}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}

/**
 * An artifact: html the agent wrote in a sandboxed frame (scripts and forms,
 * never same-origin — the page cannot reach Longx's session or storage), or
 * a URL. `srcdoc` keeps it self-contained; nothing is fetched from us.
 */
function ArtifactTab({ tab }: { tab: Extract<Tab, { kind: "artifact" }> }) {
  return (
    <div className="flex min-h-0 flex-1 flex-col" data-testid="artifact-tab">
      <iframe
        title={tab.title}
        sandbox="allow-scripts allow-forms"
        referrerPolicy="no-referrer"
        {...(tab.html !== undefined ? { srcDoc: tab.html } : { src: tab.url })}
        className="bg-background min-h-0 w-full flex-1 border-0"
      />
    </div>
  );
}

function TabIcon({ tab }: { tab: Tab }) {
  if (tab.kind === "chat") return <MessagesSquare className="size-3.5" />;
  if (tab.kind === "file") return <FileCode2 className="size-3.5" />;
  if (tab.kind === "artifact") return <AppWindow className="size-3.5" />;
  return <GitCompareArrows className="size-3.5" />;
}

function tabLabel(tab: Tab): string {
  if (tab.kind === "chat") return t.chatTab;
  if (tab.kind === "artifact") return tab.title || t.artifactTab;
  const name = tab.path.split("/").at(-1) ?? tab.path;
  return tab.kind === "diff" ? `${name} ±` : name;
}
