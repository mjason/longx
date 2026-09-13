import { useQueryClient } from "@tanstack/react-query";
import { GitBranch, History, MessagesSquare, Server, Settings, X } from "lucide-react";
import { useEffect, useState, type ReactNode } from "react";
import { Link, Outlet, useParams } from "react-router";
import { toast } from "sonner";
import { TOOLS, toolForShortcut, useFrame, type Tool } from "@/core/frame";
import { joinProjectChannel, type CodexSample } from "@/core/projectChannel";
import { queryKeys, useProject } from "@/core/projects";
import { getSocket } from "@/core/socket";
import { useViewport } from "@/core/viewport";
import { Sheet, SheetContent, SheetHeader, SheetTitle } from "@/ui/components/ui/sheet";
import { Skeleton } from "@/ui/components/ui/skeleton";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/ui/components/ui/tooltip";
import { TopBar } from "@/ui/shell/Shell";
import { ThemeToggle } from "@/ui/components/ThemeToggle";
import { ChatProvider } from "@/ui/chat/ChatProvider";
import { t } from "@/ui/strings";
import { StatusStrip } from "./StatusStrip";
import { TurnsTool } from "./tools/TurnsTool";
import { GitTool } from "./tools/GitTool";
import { ProcessTool } from "./tools/ProcessTool";
import { ThreadsTool } from "./tools/ThreadsTool";

const ICONS: Record<Tool, typeof MessagesSquare> = {
  threads: MessagesSquare,
  git: GitBranch,
  process: Server,
  history: History,
};

export type ProjectContext = {
  id: string;
  slug: string;
  name: string;
  rootPath: string;
  sandbox: string;
  approvalPolicy: string;
  sample: CodexSample | null;
};

/**
 * The IDE frame with chat in the middle. Desktop: icon rail + docked,
 * resizable tool window on the left, status bar at the bottom. Phone: the
 * chat fills the screen, tools live in a bottom toolbar and open as sheets.
 */
export function ProjectWindow() {
  const { slug = "" } = useParams();
  const project = useProject(slug);
  const viewport = useViewport();
  const frame = useFrame();
  const client = useQueryClient();
  const [sample, setSample] = useState<CodexSample | null>(null);
  const id = project.data?.id;

  useEffect(() => {
    if (!id) return;
    return joinProjectChannel(getSocket(), id, {
      onChanged: () => {
        client.invalidateQueries({ queryKey: queryKeys.threads(id) });
        client.invalidateQueries({ queryKey: ["turns"] });
      },
      onCodex: (status) => {
        client.invalidateQueries({ queryKey: queryKeys.codex(id) });
        if (status === "down") toast.warning(t.codexDown);
        else toast.success(t.codexReady);
      },
      onSample: setSample,
    });
  }, [client, id]);

  // sheets start closed: the chat comes first on a phone; the docked layout
  // remembers which tool was open
  const docked = viewport === "desktop";
  useEffect(() => {
    if (!docked) frame.close();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [docked]);

  // ⌘/Ctrl+1..4 toggle tool windows (desktop habit; harmless elsewhere)
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (!(e.metaKey || e.ctrlKey)) return;
      const tool = toolForShortcut(e.key);
      if (tool) {
        e.preventDefault();
        frame.toggle(tool);
      }
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [frame]);

  if (project.isPending) return <Skeleton className="m-4 h-32" />;
  if (project.isError) return <p role="alert" className="text-destructive p-4">{project.error.message}</p>;

  const ctx: ProjectContext = {
    id: project.data.id,
    slug,
    name: project.data.name,
    rootPath: project.data.rootPath,
    sandbox: project.data.sandbox,
    approvalPolicy: project.data.approvalPolicy,
    sample,
  };

  return (
    // fixed height: the chat scrolls inside its own viewport, not the page
    <ChatProvider
      projectId={project.data.id}
      slug={slug}
      defaults={{ sandbox: project.data.sandbox, approvalPolicy: project.data.approvalPolicy, networkAccess: project.data.networkAccess, webSearch: project.data.webSearch }}
    >
    <div className="flex h-dvh flex-col">
      <TopBar
        wide
        title={project.data.name}
        back="/"
        actions={
          <>
          <ThemeToggle />
          <Link to={`/p/${slug}/settings`} aria-label={t.settings} className="touch-target flex items-center justify-center rounded-md">
            <Settings className="size-5" />
          </Link>
          </>
        }
      />
      <div className="flex min-h-0 flex-1 overflow-hidden">
        {docked ? <ToolRail active={frame.tool} onToggle={frame.toggle} /> : null}
        {docked && frame.tool ? (
          <DockedPanel width={frame.panelWidth} onResize={frame.resize} title={t.tools[frame.tool]!} onClose={frame.close}>
            <ToolBody tool={frame.tool} ctx={ctx} />
          </DockedPanel>
        ) : null}
        <main className="flex min-h-0 min-w-0 flex-1 flex-col overflow-y-auto">
          <Outlet context={ctx} />
        </main>
      </div>
      <StatusStrip ctx={ctx} />
      {!docked ? (
        <>
          <BottomToolbar active={frame.tool} onToggle={frame.toggle} />
          <Sheet open={frame.tool != null} onOpenChange={(open) => (open ? null : frame.close())}>
            <SheetContent side="bottom" className="safe-bottom max-h-[85dvh] overflow-y-auto rounded-t-xl" data-testid="tool-sheet">
              <SheetHeader className="pb-2">
                <SheetTitle>{frame.tool ? t.tools[frame.tool] : ""}</SheetTitle>
              </SheetHeader>
              {frame.tool ? <ToolBody tool={frame.tool} ctx={ctx} /> : null}
            </SheetContent>
          </Sheet>
        </>
      ) : null}
    </div>
    </ChatProvider>
  );
}

function ToolBody({ tool, ctx }: { tool: Tool; ctx: ProjectContext }) {
  switch (tool) {
    case "threads":
      return <ThreadsTool />;
    case "git":
      return <GitTool ctx={ctx} />;
    case "process":
      return <ProcessTool ctx={ctx} />;
    case "history":
      return <TurnsTool ctx={ctx} />;
  }
}

function ToolRail({ active, onToggle }: { active: Tool | null; onToggle: (tool: Tool) => void }) {
  return (
    <nav aria-label="工具窗口" className="bg-background flex w-11 shrink-0 flex-col items-center gap-1 border-r py-2" data-testid="tool-rail">
      {TOOLS.map((tool, i) => {
        const Icon = ICONS[tool];
        return (
          <Tooltip key={tool}>
            <TooltipTrigger asChild>
              <button
                type="button"
                aria-label={t.tools[tool]}
                aria-pressed={active === tool}
                onClick={() => onToggle(tool)}
                className={`flex size-9 items-center justify-center rounded-md ${active === tool ? "bg-accent text-foreground" : "text-muted-foreground hover:text-foreground"}`}
              >
                <Icon className="size-5" />
              </button>
            </TooltipTrigger>
            <TooltipContent side="right">
              {t.tools[tool]} <kbd className="text-muted-foreground ml-1 text-[10px]">⌘{i + 1}</kbd>
            </TooltipContent>
          </Tooltip>
        );
      })}
    </nav>
  );
}

function DockedPanel({ width, onResize, title, onClose, children }: { width: number; onResize: (w: number) => void; title: string; onClose: () => void; children: ReactNode }) {
  function startDrag(e: React.PointerEvent) {
    const startX = e.clientX;
    const startW = width;
    const move = (ev: PointerEvent) => onResize(startW + ev.clientX - startX);
    const up = () => {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
    };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
  }
  return (
    <aside className="bg-card relative flex shrink-0 flex-col border-r" style={{ width }} data-testid="tool-panel">
      <div className="flex h-9 items-center justify-between border-b px-3 text-xs font-medium uppercase tracking-wide">
        {title}
        <button type="button" aria-label={t.close} onClick={onClose} className="text-muted-foreground hover:text-foreground rounded p-1">
          <X className="size-4" />
        </button>
      </div>
      <div className="min-h-0 flex-1 overflow-y-auto p-3">{children}</div>
      <div role="separator" aria-orientation="vertical" onPointerDown={startDrag} className="hover:bg-primary/40 absolute inset-y-0 -right-1 w-2 cursor-col-resize" />
    </aside>
  );
}

function BottomToolbar({ active, onToggle }: { active: Tool | null; onToggle: (tool: Tool) => void }) {
  return (
    <nav aria-label="工具窗口" className="safe-bottom bg-background/95 sticky bottom-0 z-20 border-t backdrop-blur" data-testid="bottom-toolbar">
      <div className="flex">
        {TOOLS.map((tool) => {
          const Icon = ICONS[tool];
          return (
            <button
              key={tool}
              type="button"
              aria-label={t.tools[tool]}
              aria-pressed={active === tool}
              onClick={() => onToggle(tool)}
              className={`flex h-14 flex-1 flex-col items-center justify-center gap-0.5 text-[11px] ${active === tool ? "text-primary" : "text-muted-foreground"}`}
            >
              <Icon className="size-5" />
              {t.tools[tool]}
            </button>
          );
        })}
      </div>
    </nav>
  );
}
