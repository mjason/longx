import { AssistantRuntimeProvider } from "@assistant-ui/react";
import { createContext, useCallback, useContext, useState, type ReactNode } from "react";
import { useNavigate, useParams } from "react-router";
import type { AccessMode, DirtyChange, DirtyDecision } from "@/core/chat/adapter";
import { useCodexRuntime, type CodexRuntime } from "@/core/chat/runtime";
import { DirtyTreeDialog, type DirtyPrompt } from "./DirtyTreeDialog";
import { chatConfig, CompactionUI, PlanUI } from "./toolkit";

const ChatContext = createContext<CodexRuntime | null>(null);

/** The chat runtime for the project window: the thread in the route, or a new chat. */
export function useChat(): CodexRuntime {
  const ctx = useContext(ChatContext);
  if (!ctx) throw new Error("useChat outside ChatProvider");
  return ctx;
}

/**
 * Mounts assistant-ui's runtime for the whole project window, so the
 * thread list tool and the chat in the centre share one runtime; the
 * dirty-tree question is the one piece of DOM this needs.
 */
export function ChatProvider({ projectId, slug, defaults, defaultModelId, children }: { projectId: string; slug: string; defaults: AccessMode; defaultModelId?: string | null; children: ReactNode }) {
  const { threadId } = useParams();
  const navigate = useNavigate();
  const [dirty, setDirty] = useState<DirtyPrompt | null>(null);

  // null: the thread on screen was deleted or archived → the project's new chat
  const onOpenThread = useCallback((id: string | null) => navigate(id ? `/p/${slug}/t/${id}` : `/p/${slug}`), [navigate, slug]);
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

  const chat = useCodexRuntime({ projectId, defaults, defaultModelId, threadId, onOpenThread, onDirtyTree });

  return (
    <ChatContext.Provider value={chat}>
      <AssistantRuntimeProvider runtime={chat.runtime} config={chatConfig}>
        <PlanUI />
        <CompactionUI />
        {children}
        <DirtyTreeDialog prompt={dirty} />
      </AssistantRuntimeProvider>
    </ChatContext.Provider>
  );
}
