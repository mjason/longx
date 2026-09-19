import { AssistantRuntimeProvider, useAui } from "@assistant-ui/react";
import { answerRequest, interruptTurn } from "@/ash_rpc";
import { unwrap, useSubagents } from "@/core/projects";
import { runningTurnId } from "@/core/chat/thread";
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { useNavigate, useParams } from "react-router";
import { useLongxRuntime, type LongxRuntime } from "@/core/chat/runtime";
import { toast } from "sonner";
import { t } from "@/ui/strings";
import { GoalProvider } from "./GoalBar";
import { useWorkbench, type Tab } from "@/core/workbench";
import { ActionAnswerContext, chatConfig, CompactionUI, GoalContinuationUI, SubagentContext, SurfaceContext } from "./toolkit";

const ChatContext = createContext<LongxRuntime | null>(null);

/** The runtime when inside a project window, null elsewhere (a tool UI rendered on its own). */
export function useChatMaybe(): LongxRuntime | null {
  return useContext(ChatContext);
}

/** The chat runtime for the project window: the thread in the route, or a new chat. */
export function useChat(): LongxRuntime {
  const ctx = useContext(ChatContext);
  if (!ctx) throw new Error("useChat outside ChatProvider");
  return ctx;
}

/**
 * Mounts assistant-ui's runtime for the whole project window, so the
 * thread list tool and the chat in the centre share one runtime.
 */
export function ChatProvider({
  projectId,
  slug,
  webSearch,
  defaultModelId,
  children,
}: {
  projectId: string;
  slug: string;
  webSearch?: boolean;
  defaultModelId?: string | null;
  children: ReactNode;
}) {
  const { threadId } = useParams();
  const navigate = useNavigate();

  // null: the thread on screen was deleted or archived → the project's new chat
  const onOpenThread = useCallback(
    (id: string | null) => navigate(id ? `/p/${slug}/t/${id}` : `/p/${slug}`),
    [navigate, slug],
  );
  // where the agent's surfaces open: the project's workbench (a tab; a sheet on a phone)
  const workbench = useWorkbench(projectId);
  const openSurface = workbench.open;
  const surface = useMemo(() => ({ projectId, open: openSurface }), [projectId, openSurface]);

  // the kernel fell back to another model of the alias chain under the turn: say so;
  // a surface the agent opened *live* (show_file / show_diff / show_html) opens here —
  // a replayed item never signals, so a reload leaves the workbench as the person had it
  const onSignal = useCallback(
    (method: string, params: Record<string, unknown>) => {
      if (method === "item/completed") {
        const tab = surfaceTab(params["item"] as Record<string, unknown>);
        if (tab) openSurface(tab);
        return;
      }
      if (method === "model/rerouted") {
        const reason =
          t.modelReroutedReason[String(params["reason"])] ??
          String(params["reason"] ?? "");
        toast.warning(
          t.modelRerouted(
            String(params["fromModel"]),
            String(params["toModel"]),
          ),
          { description: reason },
        );
      }
    },
    [openSurface],
  );

  // a stop before anything came back: the message's text goes back into the
  // composer (assistant-ui's composer lives under the runtime provider below)
  const composerRef = useRef<((text: string) => void) | null>(null);
  const onRetract = useCallback(
    (text: string) => composerRef.current?.(text),
    [],
  );

  const chat = useLongxRuntime({
    projectId,
    ...(webSearch !== undefined ? { webSearch } : {}),
    defaultModelId,
    threadId,
    onOpenThread,
    onSignal,
    onRetract,
  });

  // a tool's ask (Context.ask) is answered on the thread on screen — the
  // sub-agents' asks too, since their conversations nest under it
  const rowId = chat.thread?.id;
  const answerAction = useCallback(
    async (requestId: string, answers: Record<string, unknown>) => {
      if (!rowId) return;
      unwrap(
        await answerRequest({ input: { threadId: rowId, requestId, answers } }),
      );
    },
    [rowId],
  );

  // a sub-agent stopped from the parent's page: its row, its running turn
  const subagentRows = useSubagents(rowId);
  const subviews = chat.subviews;
  const rows = subagentRows.data;
  const subagentContext = useMemo(
    () => ({
      views: subviews,
      stop: async (kernelThreadId: string) => {
        const row = rows?.find((r) => r.kernelThreadId === kernelThreadId);
        const view = subviews[kernelThreadId];
        const turnId = view ? runningTurnId(view) : null;
        if (!row || !turnId) return;
        unwrap(await interruptTurn({ input: { threadId: row.id, kernelTurnId: turnId } }));
      },
      // the child's conversation as a workbench tab (its row id is its page)
      open: (kernelThreadId: string, name: string) => {
        const row = rows?.find((r) => r.kernelThreadId === kernelThreadId);
        openSurface({ kind: "agent", threadId: kernelThreadId, rowId: row?.id ?? null, name });
      },
    }),
    [rows, subviews, openSurface],
  );

  return (
    <ChatContext.Provider value={chat}>
      <AssistantRuntimeProvider runtime={chat.runtime} config={chatConfig}>
        <ComposerBridge composerRef={composerRef} />
        <CompactionUI />
        <GoalContinuationUI />
        <SurfaceContext.Provider value={surface}>
      <ActionAnswerContext.Provider value={answerAction}>
        <SubagentContext.Provider value={subagentContext}>
          <GoalProvider threadId={chat.thread?.id} goal={chat.view.goal}>
            {children}
          </GoalProvider>
        </SubagentContext.Provider>
        </ActionAnswerContext.Provider>
      </SurfaceContext.Provider>
      </AssistantRuntimeProvider>
    </ChatContext.Provider>
  );
}

// reaches the composer from outside the runtime provider (the adapter's onRetract)
function ComposerBridge({
  composerRef,
}: {
  composerRef: React.MutableRefObject<((text: string) => void) | null>;
}) {
  const aui = useAui();
  useEffect(() => {
    composerRef.current = (text) => aui.composer.setText(text);
    return () => {
      composerRef.current = null;
    };
  }, [aui, composerRef]);
  return null;
}

/** The workbench tab a live surface item asks for, null for anything else. */
function surfaceTab(item: Record<string, unknown> | undefined): Tab | null {
  if (!item || item["type"] !== "dynamicToolCall" || item["namespace"] !== "longx" || item["success"] !== true) return null;
  const args = (item["arguments"] ?? {}) as Record<string, unknown>;
  const details = (item["details"] ?? {}) as Record<string, unknown>;
  const path = typeof details["path"] === "string" ? details["path"] : null;
  switch (item["tool"]) {
    case "show_file":
      return path ? { kind: "file", path, ...(typeof details["line"] === "number" ? { line: details["line"] } : {}) } : null;
    case "show_diff":
      return path ? { kind: "diff", path, sha: typeof details["sha"] === "string" ? details["sha"] : null } : null;
    case "show_html": {
      const title = String(details["title"] ?? args["title"] ?? "");
      if (typeof args["html"] === "string" && args["html"]) return { kind: "artifact", id: String(item["id"]), title, html: args["html"] };
      if (typeof args["url"] === "string" && args["url"]) return { kind: "artifact", id: String(item["id"]), title, url: args["url"] };
      return null;
    }
    default:
      return null;
  }
}
