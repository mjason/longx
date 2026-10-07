import { createContext, memo, useCallback, useContext, useEffect, useLayoutEffect, useRef, useState, useSyncExternalStore, type ReactNode } from "react";
import { useLongxRuntime } from "@/core/chat/runtime";
import { ChatSessionPool, sessionKey, type ChatSession, type SessionOptions } from "@/core/chat/sessionPool";
import { useProjectDraft } from "./useProjectDraft";

const SessionsContext = createContext<ChatSessionPool | null>(null);

const SessionHost = memo(function SessionHost({ pool, entry, options }: {
  pool: ChatSessionPool; entry: ChatSession; options: SessionOptions;
}) {
  const onOpenThread = useCallback((threadId: string | null) => pool.openThread(entry, threadId), [pool, entry]);
  const onAttachmentActivity = useCallback((count: number) => pool.attachmentActivity(entry, count), [pool, entry]);
  const chat = useLongxRuntime({ ...options, onOpenThread, onAttachmentActivity });
  useProjectDraft(options.projectId, options.threadId, chat.runtime);
  useLayoutEffect(() => pool.publish(entry, chat), [pool, entry, chat]);
  useEffect(() => chat.runtime.thread.composer.subscribe(() => pool.schedulePrune(entry)), [pool, entry, chat.runtime]);
  return null;
});

/** Own the runtimes above the router outlet so project navigation cannot
 * destroy an upload or a queue. Only the visible session renders chat UI. */
export function ChatSessions({ children }: { children: ReactNode }) {
  const [pool] = useState(() => new ChatSessionPool());
  const sessions = useSyncExternalStore(pool.subscribeSessions, pool.getSessions);
  useEffect(() => () => pool.clear(), [pool]);
  return (
    <SessionsContext.Provider value={pool}>
      {children}
      {sessions.map(entry => <SessionHost key={entry.id} pool={pool} entry={entry} options={entry.options} />)}
    </SessionsContext.Provider>
  );
}

export function useChatSession(options: SessionOptions) {
  const pool = useContext(SessionsContext);
  if (!pool) throw new Error("useChatSession outside ChatSessions");
  const key = sessionKey(options.projectId, options.threadId);
  const current = useRef<ChatSession | null>(null);
  useLayoutEffect(() => {
    const entry = pool.acquire(options);
    current.current = entry;
    return () => {
      current.current = null;
      pool.release(entry);
    };
    // The options update below does not detach/re-acquire a session.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [pool, key]);
  useLayoutEffect(() => {
    if (current.current) pool.update(current.current, options);
  }, [pool, options]);
  return useSyncExternalStore(pool.subscribeValues, () => pool.getChat(key));
}
