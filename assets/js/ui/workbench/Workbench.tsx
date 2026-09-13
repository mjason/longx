// The centre of the project window as an editor area: a tab strip — the
// chat first and always, then the files and diffs opened from the tools —
// over whichever is active. The chat stays mounted behind a file so its
// scroll and composer draft survive a look at the code.
import { FileCode2, GitCompareArrows, MessagesSquare, X } from "lucide-react";
import type { ReactNode } from "react";
import { tabKey, useWorkbench, type Tab } from "@/core/workbench";
import { t } from "@/ui/strings";
import { DiffTab } from "./DiffTab";
import { EditorTab } from "./EditorTab";

export function Workbench({ projectId, children }: { projectId: string; children: ReactNode }) {
  const wb = useWorkbench(projectId);
  const active = wb.tabs.find((tab) => tabKey(tab) === wb.active) ?? wb.tabs[0]!;

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
                  <button type="button" aria-label={`${t.closeTab} ${tabLabel(tab)}`} className="text-muted-foreground hover:text-foreground rounded p-0.5" onClick={() => wb.close(key)}>
                    <X className="size-3" />
                  </button>
                ) : null}
              </div>
            );
          })}
        </div>
      ) : null}
      <div className={`min-h-0 flex-1 flex-col ${active.kind === "chat" ? "flex" : "hidden"}`}>{children}</div>
      {active.kind === "file" ? <EditorTab key={active.path} projectId={projectId} path={active.path} /> : null}
      {active.kind === "diff" ? <DiffTab key={tabKey(active)} projectId={projectId} path={active.path} sha={active.sha} /> : null}
    </div>
  );
}

function TabIcon({ tab }: { tab: Tab }) {
  if (tab.kind === "chat") return <MessagesSquare className="size-3.5" />;
  if (tab.kind === "file") return <FileCode2 className="size-3.5" />;
  return <GitCompareArrows className="size-3.5" />;
}

function tabLabel(tab: Tab): string {
  if (tab.kind === "chat") return t.chatTab;
  const name = tab.path.split("/").at(-1) ?? tab.path;
  return tab.kind === "diff" ? `${name} ±` : name;
}
