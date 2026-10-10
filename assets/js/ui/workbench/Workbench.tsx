import { useTranslation } from "react-i18next";
// The centre of the project window as an editor area: a tab strip — the
// conversations, files and diffs opened from the tools — over whichever
// is active. The chat stays mounted behind a file so its
// scroll and composer draft survive a look at the code.
import { AppWindow, Bot, FileCode2, GitCompareArrows, MessagesSquare, Settings as SettingsIcon, X } from "lucide-react";
import { lazy, Suspense, useEffect, useState, type ReactNode } from "react";
import { useViewport } from "@/core/viewport";
import { stepTab, tabAt, tabKey, useWorkbench, type Tab } from "@/core/workbench";
import { openPicker } from "@/core/keys/picker";
import { useCommand } from "@/core/keys/useCommand";
import { onModifierRelease } from "@/core/keys/release";
import { keysTitle } from "@/ui/keys/hint";
import { Sheet, SheetContent, SheetHeader, SheetTitle } from "@/ui/components/ui/sheet";
import { AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle } from "@/ui/components/ui/alert-dialog";
import { t } from "@/ui/strings";
import { useLocation, useMatch, useNavigate } from "react-router";
import { useChat } from "@/ui/chat/ChatProvider";
import { useRunningThreads } from "@/core/projects";
import { AgentTab } from "./AgentTab";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { ContextMenu, ContextMenuContent, ContextMenuItem, ContextMenuTrigger } from "@/ui/components/ui/context-menu";

// the code editor and the diff (CodeMirror, ~1 MB of source) load when a file
// or a diff is first opened, not with every page
const EditorTab = lazy(async () => ({ default: (await import("./EditorTab")).EditorTab }));
const DiffTab = lazy(async () => ({ default: (await import("./DiffTab")).DiffTab }));

export function Workbench({
  projectId,
  slug,
  threadId,
  children,
}: {
  projectId: string;
  slug: string;
  threadId?: string;
  children: ReactNode;
}) {
    useTranslation();
  const wb = useWorkbench(projectId);
  const viewport = useViewport();
  const navigate = useNavigate();
  const location = useLocation();
  const settingsRoute = useMatch("/p/:slug/settings") !== null;
  const chat = useChat();
  const running = useRunningThreads();
  const chatTitle = threadId ? chat.thread?.title || chat.thread?.preview || t.chatTab : t.chatTab;
  useEffect(() => {
    if (settingsRoute) wb.open({ kind: "settings" });
    else if (threadId) wb.open({ kind: "chat", threadId, title: chatTitle });
    else if (location.state?.newChat) {
      wb.open({ kind: "chat" });
      // Consume the request: reloading later must restore the active tab,
      // not replay an old "new session" action from browser history.
      navigate(`/p/${slug}`, { replace: true });
    } else {
      // The project root restores its workspace; it is not a request for
      // a new conversation. Files and other non-route tabs stay active.
      const saved = wb.tabs.find((tab) => tabKey(tab) === wb.active);
      if (saved?.kind === "chat" && saved.threadId) navigate(`/p/${slug}/t/${saved.threadId}`, { replace: true });
      else if (saved?.kind === "settings") navigate(`/p/${slug}/settings`, { replace: true });
    }
    // Snapshot tabs on navigation, not on activation of a file or surface.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [wb.open, settingsRoute, threadId, chatTitle, location.key, navigate, slug]);
  const active = wb.tabs.find((tab) => tabKey(tab) === wb.active) ?? wb.tabs[0]!;
  // a phone has no room for a tab strip around an artifact: a full-screen sheet over the chat
  const phoneArtifact = viewport === "phone" && active.kind === "artifact" ? active : null;
  // closing a tab with unsaved edits asks first
  const [closing, setClosing] = useState<Tab | null>(null);
  const routeFor = (tab: Tab) =>
    tab.kind === "settings" ? `/p/${slug}/settings` :
      tab.kind === "chat" ? (tab.threadId ? `/p/${slug}/t/${tab.threadId}` : `/p/${slug}`) : null;
  const select = (tab: Tab) => {
    wb.activate(tabKey(tab));
    const path = routeFor(tab);
    if (path) navigate(path);
  };
  const close = (tab: Tab) => {
    if (wb.dirty.includes(tabKey(tab))) {
      setClosing(tab);
      return;
    }
    const wasActive = wb.active === tabKey(tab);
    const index = wb.tabs.findIndex((candidate) => tabKey(candidate) === tabKey(tab));
    const fallback = wasActive
      ? wb.tabs.filter((candidate) => tabKey(candidate) !== tabKey(tab))[Math.min(index, wb.tabs.length - 2)] ?? { kind: "chat" as const }
      : undefined;
    wb.close(tabKey(tab));
    if (wasActive) {
      const path = fallback && routeFor(fallback);
      if (path) navigate(path);
      else if (tab.kind === "chat" && tab.threadId) navigate(`/p/${slug}`);
    }
  };
  useTabCommands(wb, active, close, select);

  return (
    <div className="flex min-h-0 flex-1 flex-col" data-testid="workbench">
      <div role="tablist" aria-label={t.workbench} className="bg-sidebar border-sidebar-border flex h-9 shrink-0 items-stretch overflow-x-auto border-b" data-testid="workbench-tabs">
          {wb.tabs.map((tab) => {
            const key = tabKey(tab);
            const isActive = key === wb.active;
            return (
              <ContextMenu key={key}>
                <ContextMenuTrigger asChild>
                  <div
                    role="tab"
                    aria-selected={isActive}
                    className={`group flex shrink-0 items-center gap-1.5 border-r px-3 text-xs ${isActive ? "bg-background text-foreground" : "text-muted-foreground hover:text-foreground"}`}
                  >
                    <button type="button" className="flex h-full items-center gap-1.5" onClick={() => select(tab)}>
                      <TabIcon tab={tab} />
                      <span className="max-w-48 truncate font-mono">{tabLabel(tab)}</span>
                      {tab.kind === "chat" && running.data?.find(row => row.id === tab.threadId)?.jobActivity?.total ? (
                        <span className="text-warning text-[10px]" title={t.jobWork.states[running.data.find(row => row.id === tab.threadId)!.jobActivity!.state]} aria-label={t.jobWork.states[running.data.find(row => row.id === tab.threadId)!.jobActivity!.state]}>●</span>
                      ) : null}
                      {wb.dirty.includes(key) ? <span className="text-warning" title={t.unsavedChanges}>●</span> : null}
                    </button>
                    {tab.kind !== "chat" || !!tab.threadId ? (
                      <button type="button" aria-label={`${t.closeTab} ${tabLabel(tab)}`} title={keysTitle(t.closeTab, "tab.close")} className="text-muted-foreground hover:text-foreground rounded p-0.5" onClick={() => close(tab)}>
                        <X className="size-3" />
                      </button>
                    ) : null}
                  </div>
                </ContextMenuTrigger>
                <ContextMenuContent>
                  <ContextMenuItem onSelect={() => select(tab)}>{t.switchToTab}</ContextMenuItem>
                  {tab.kind !== "chat" || !!tab.threadId ? <ContextMenuItem onSelect={() => close(tab)}>{t.closeTab}</ContextMenuItem> : null}
                </ContextMenuContent>
              </ContextMenu>
            );
          })}
      </div>
      <div
        data-chat-workbench-active={active.kind === "chat" ? "true" : "false"}
        className={`min-h-0 flex-1 flex-col ${active.kind === "chat" || active.kind === "settings" ? "flex" : "hidden"}`}
      >
        {children}
      </div>
      <Suspense fallback={<Skeleton className="m-4 h-32" />}>
        {active.kind === "file" ? <EditorTab key={`${projectId}:${active.path}`} projectId={projectId} path={active.path} line={active.line} /> : null}
        {active.kind === "diff" ? <DiffTab key={tabKey(active)} projectId={projectId} path={active.path} sha={active.sha} /> : null}
      </Suspense>
      {active.kind === "artifact" && !phoneArtifact ? <ArtifactTab key={tabKey(active)} tab={active} /> : null}
      {active.kind === "agent" ? <AgentTab key={tabKey(active)} threadId={active.threadId} rowId={active.rowId} name={active.name} /> : null}
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
  if (tab.kind === "settings") return <SettingsIcon className="size-3.5" />;
  if (tab.kind === "file") return <FileCode2 className="size-3.5" />;
  if (tab.kind === "artifact") return <AppWindow className="size-3.5" />;
  if (tab.kind === "agent") return <Bot className="size-3.5" />;
  return <GitCompareArrows className="size-3.5" />;
}

function tabLabel(tab: Tab): string {
  if (tab.kind === "chat") return tab.title ?? (tab.threadId ? t.chatTab : t.newThread);
  if (tab.kind === "settings") return t.projectSettingsTab;
  if (tab.kind === "artifact") return tab.title || t.artifactTab;
  if (tab.kind === "agent") return tab.name;
  const name = tab.path.split("/").at(-1) ?? tab.path;
  return tab.kind === "diff" ? `${name} ±` : name;
}

/**
 * The space menu's tab commands (SPC b, SPC TAB, SPC 1…9), here because
 * closing a tab with unsaved edits asks first — the same `close` the ×
 * uses. The same keys work for every kind of tab: a file, a diff, an agent,
 * an artifact.
 */
function useTabCommands(wb: ReturnType<typeof useWorkbench>, active: Tab, close: (tab: Tab) => void, select: (tab: Tab) => void) {
  const state = { tabs: wb.tabs, active: wb.active, dirty: wb.dirty };
  const many = () => wb.tabs.length > 1;
  useCommand("tab.close", () => close(active), () => active.kind !== "chat" || !!active.threadId);
  useCommand("tab.reopen", wb.reopen, wb.canReopen);
  useCommand("tab.last", () => {
    wb.back();
    const tab = wb.tabs.find((candidate) => tabKey(candidate) === wb.activeKey());
    if (tab) select(tab);
  }, many);
  // the installed app's Ctrl+Tab: by last use while Ctrl is held
  useCommand("tab.recent", () => {
    wb.cycle(1);
    const tab = wb.tabs.find((candidate) => tabKey(candidate) === wb.activeKey());
    if (tab) select(tab);
  }, many);
  useCommand("tab.recentBack", () => {
    wb.cycle(-1);
    const tab = wb.tabs.find((candidate) => tabKey(candidate) === wb.activeKey());
    if (tab) select(tab);
  }, many);
  useEffect(() => onModifierRelease(wb.endCycle), [wb.endCycle]);
  useCommand("tab.next", () => {
    const tab = wb.tabs.find((candidate) => tabKey(candidate) === stepTab(state, 1).active);
    if (tab) select(tab);
  }, many);
  useCommand("tab.prev", () => {
    const tab = wb.tabs.find((candidate) => tabKey(candidate) === stepTab(state, -1).active);
    if (tab) select(tab);
  }, many);
  useCommand("tab.chat", () => {
    const tab = wb.tabs.find((candidate) => tabKey(candidate) === "chat");
    if (tab) select(tab);
  }, () => active.kind !== "chat");
  useCommand(
    "tab.switch",
    () =>
      openPicker({
        title: t.keys.switchTab,
        items: wb.tabs.map((tab) => ({
          id: tabKey(tab),
          label: tabLabel(tab),
          ...(tab.kind === "file" || tab.kind === "diff" ? { detail: tab.path } : {}),
        })),
        onPick: (item) => {
          const tab = wb.tabs.find((candidate) => tabKey(candidate) === item.id);
          if (tab) select(tab);
        },
      }),
    many,
  );
  // SPC 1…9: nine registrations, always in the same order
  for (let n = 1; n <= 9; n++) {
    // eslint-disable-next-line react-hooks/rules-of-hooks
    useCommand(`tab.goto.${n}`, () => {
      const key = tabAt(state, n);
      const tab = key && wb.tabs.find((candidate) => tabKey(candidate) === key);
      if (tab) select(tab);
    }, () => wb.tabs.length > 1 && tabAt(state, n) !== null);
  }
}
