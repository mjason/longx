import { AssistantRuntimeProvider, useAui } from "@assistant-ui/react";
import { answerRequest } from "@/ash_rpc";
import { unwrap } from "@/core/projects";
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { useNavigate, useParams } from "react-router";
import type { DirtyChange, DirtyDecision } from "@/core/chat/adapter";
import { useLongxRuntime, type LongxRuntime } from "@/core/chat/runtime";
import { toast } from "sonner";
import { t } from "@/ui/strings";
import { DirtyTreeDialog, type DirtyPrompt } from "./DirtyTreeDialog";
import { GoalProvider } from "./GoalBar";
import { ActionAnswerContext, chatConfig, CompactionUI } from "./toolkit";

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
 * thread list tool and the chat in the centre share one runtime; the
 * dirty-tree question is the one piece of DOM this needs.
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
  const [dirty, setDirty] = useState<DirtyPrompt | null>(null);

  // null: the thread on screen was deleted or archived → the project's new chat
  const onOpenThread = useCallback(
    (id: string | null) => navigate(id ? `/p/${slug}/t/${id}` : `/p/${slug}`),
    [navigate, slug],
  );
  const onDirtyTree = useCallback(
    (changes: DirtyChange[]) =>
      new Promise<DirtyDecision>((resolve) => {
        setDirty({
          changes,
          resolve: (decision) => {
            setDirty(null);
            resolve(decision);
          },
        });
      }),
    [],
  );

  // the kernel fell back to another model of the alias chain under the turn: say so
  const onSignal = useCallback(
    (method: string, params: Record<string, unknown>) => {
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
    [],
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
    onDirtyTree,
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

  return (
    <ChatContext.Provider value={chat}>
      <AssistantRuntimeProvider runtime={chat.runtime} config={chatConfig}>
        <ComposerBridge composerRef={composerRef} />
        <CompactionUI />
        <ActionAnswerContext.Provider value={answerAction}>
          <GoalProvider threadId={chat.thread?.id} goal={chat.view.goal}>
            {children}
          </GoalProvider>
        </ActionAnswerContext.Provider>
        <DirtyTreeDialog prompt={dirty} />
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
