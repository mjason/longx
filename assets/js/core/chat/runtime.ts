// `useCodexRuntime`: one hook that turns a project + the thread in the
// route into an assistant-ui runtime — the same shape as
// @assistant-ui/react-opencode (ExternalStoreRuntime over a coding-agent
// server): the thread list, the live view, the composer queue, the
// per-turn model and the extras renderers call back into. DOM-free; the
// router comes in as `onOpenThread`, so a React Native app can reuse it.
import { createMessageQueue, useExternalStoreRuntime, type AppendMessage, type AssistantRuntime } from "@assistant-ui/react";
import { useQueryClient } from "@tanstack/react-query";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { archiveThread, deleteThread, renameThread } from "@/ash_rpc";
import { queryKeys, unwrap, useStartThread, useThreads } from "@/core/projects";
import { buildAdapter, type AccessMode, type DirtyChange, type DirtyDecision, type ThreadTarget } from "./adapter";
import { runningTurnId, type ThreadView } from "./thread";
import { buildThreadListAdapter, type ThreadRow } from "./threadList";
import { useThreadView } from "./useThreadView";

export type CodexRuntimeOptions = {
  projectId: string;
  /** the project's defaults: what a new chat starts with */
  defaults: AccessMode;
  /** the thread row id from the route; undefined = new chat (the first message creates one) */
  threadId: string | undefined;
  onOpenThread: (threadId: string) => void;
  onDirtyTree?: (changes: DirtyChange[]) => Promise<DirtyDecision>;
};

export type TurnState = "idle" | "running" | "approval";

export type CodexRuntime = {
  runtime: AssistantRuntime;
  thread: ThreadRow | undefined;
  /** the route names a thread the project does not have */
  missing: boolean;
  view: ThreadView;
  ready: boolean;
  error: string | null;
  state: TurnState;
  /** why the thread cannot take messages, if so */
  disabledReason: string | null;
  model: string | null;
  setModel: (slug: string | null) => void;
  /** the access mode the next turn runs with */
  mode: AccessMode;
  setMode: (mode: AccessMode) => void;
};

// statuses that end a thread for good vs. a codex on its way back
const CLOSED = new Set(["unrecoverable", "archived"]);

export function useCodexRuntime(opts: CodexRuntimeOptions): CodexRuntime {
  const { projectId, defaults, threadId, onOpenThread, onDirtyTree } = opts;
  const client = useQueryClient();
  const threads = useThreads(projectId);
  const rows = useMemo(() => (threads.data ?? []) as ThreadRow[], [threads.data]);
  const thread = threadId ? rows.find((t) => t.id === threadId) : undefined;
  const { view, ready, error, refetch } = useThreadView(thread?.codexThreadId);
  const [model, setModel] = useState<string | null>(null);
  const start = useStartThread(projectId);

  // the model choice is per thread; the mode starts from what the thread
  // runs with (the row) and is only overridden by an explicit choice
  useEffect(() => setModel(null), [threadId]);
  const [modeOverride, setModeOverride] = useState<{ threadId: string | undefined; mode: AccessMode } | null>(null);
  const rowMode: AccessMode | null = thread
    ? {
        sandbox: thread.sandbox as AccessMode["sandbox"],
        approvalPolicy: thread.approvalPolicy as AccessMode["approvalPolicy"],
        networkAccess: thread.networkAccess ?? false,
        webSearch: thread.webSearch ?? true,
      }
    : null;
  const mode = modeOverride && modeOverride.threadId === threadId ? modeOverride.mode : (rowMode ?? defaults);
  const setMode = useCallback((next: AccessMode) => setModeOverride({ threadId, mode: next }), [threadId]);

  const invalidate = useCallback(() => client.invalidateQueries({ queryKey: queryKeys.threads(projectId) }), [client, projectId]);

  // a new chat starts in the mode picked in the rail (web search is start-only)
  const createThread = useCallback(async (): Promise<ThreadTarget> => {
    const row = await start.mutateAsync(mode);
    return { threadId: row.id, codexThreadId: row.codexThreadId };
  }, [start, mode]);

  const threadList = useMemo(
    () =>
      buildThreadListAdapter({
        rows,
        currentId: threadId,
        loading: threads.isPending,
        actions: {
          switchTo: onOpenThread,
          create: async () => onOpenThread((await createThread()).threadId),
          rename: async (id, title) => {
            unwrap(await renameThread({ identity: id, input: { title } }));
            await invalidate();
          },
          archive: async (id) => {
            unwrap(await archiveThread({ identity: id }));
            await invalidate();
          },
          delete: async (id) => {
            unwrap(await deleteThread({ input: { threadId: id } }));
            await invalidate();
          },
        },
      }),
    [rows, threadId, threads.isPending, onOpenThread, createThread, invalidate],
  );

  // messages sent while a turn runs wait in assistant-ui's queue and go out
  // through the adapter's onNew once it settles; the driver reads the
  // latest adapter through a ref because the adapter is rebuilt per view
  const onNewRef = useRef<(message: AppendMessage) => Promise<void>>(async () => {});
  const [queue] = useState(() => createMessageQueue({ run: (message) => void onNewRef.current(message) }));

  const disabledReason = thread && CLOSED.has(thread.status) ? thread.status : null;
  const target = thread ? { threadId: thread.id, codexThreadId: thread.codexThreadId } : null;
  const onSent = useCallback(
    (sent: ThreadTarget) => {
      void invalidate();
      if (sent.threadId !== threadId) onOpenThread(sent.threadId);
    },
    [invalidate, threadId, onOpenThread],
  );

  const adapter = useMemo(
    () =>
      buildAdapter({
        target,
        view,
        model,
        mode,
        disabled: disabledReason !== null,
        sendDisabled: thread?.status === "disconnected" || (thread !== undefined && !ready),
        loading: thread !== undefined && !ready && !error,
        createThread,
        onSent,
        onDirtyTree,
        refetch,
        threadList,
        queue: queue.adapter,
      }),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [target?.threadId, target?.codexThreadId, view, model, mode, disabledReason, thread?.status, ready, error, createThread, onSent, onDirtyTree, refetch, threadList, queue],
  );
  onNewRef.current = adapter.onNew;
  const runtime = useExternalStoreRuntime(adapter);

  const running = adapter.isRunning ?? false;
  const wasRunning = useRef(running);
  useEffect(() => {
    if (!wasRunning.current && running) queue.notifyBusy();
    if (wasRunning.current && !running) queue.notifyIdle();
    wasRunning.current = running;
  }, [running, queue]);

  const state: TurnState = thread && view.requests.length > 0 ? "approval" : thread && runningTurnId(view) ? "running" : "idle";

  return {
    runtime,
    thread,
    missing: threadId !== undefined && !threads.isPending && thread === undefined,
    view,
    ready,
    error,
    state,
    disabledReason,
    model,
    setModel,
    mode,
    setMode,
  };
}
