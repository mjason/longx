// `useLongxRuntime`: one hook that turns a project + the thread in the
// route into an assistant-ui runtime — the same shape as
// @assistant-ui/react-opencode (ExternalStoreRuntime over a coding-agent
// server): the thread list, the live view, the
// per-turn model and the extras renderers call back into. DOM-free; the
// router comes in as `onOpenThread`, so a React Native app can reuse it.
import {
  useExternalStoreRuntime,
  type AppendMessage,
  type AssistantRuntime,
} from "@assistant-ui/react";
import { useQueryClient } from "@tanstack/react-query";
import { useCallback, useEffect, useMemo, useReducer, useRef, useState } from "react";
import { archiveThread, deleteThread, releaseWaiting as releaseWaitingRpc, renameThread, retractTurn, sendMessage, steerTurn } from "@/ash_rpc";
import { queryKeys, unwrap, useAgentDefinition, useStartThread, useThread, useThreads } from "@/core/projects";
import {
  CompositeAttachmentAdapter,
  SimpleImageAttachmentAdapter,
  SimpleTextAttachmentAdapter,
  WebSpeechDictationAdapter,
  createMessageQueue,
} from "@assistant-ui/react";
import {
  buildAdapter,
  type ThreadTarget,
} from "./adapter";
import { subagentsOf, turnCount, type SubViews } from "./messages";
import { runningTurnId, type ThreadView } from "./thread";
import { csrfToken } from "@/core/rpcHooks";
import { FileUploadAttachmentAdapter } from "./fileAttachments";
import { buildThreadListAdapter, type ThreadRow } from "./threadList";
import { useThreadView } from "./useThreadView";
import { useThreadViews } from "./useThreadViews";

export type LongxRuntimeOptions = {
  projectId: string;
  /** the project's default for a new chat: whether the model may search the web */
  webSearch?: boolean;
  /** the project's own default model (a `Longx.AI.Model` id; null = the global default) */
  defaultModelId?: string | null;
  /** the thread row id from the route; undefined = new chat (the first message creates one) */
  threadId: string | undefined;
  /** navigate to a thread; null = the project's new chat (after the thread on screen is gone) */
  onOpenThread: (threadId: string | null) => void;
  /** a thread event worth telling the person about as it happens (model/rerouted) */
  onSignal?: (method: string, params: Record<string, unknown>) => void;
};

/** idle, a turn running, or a tool waiting on the person (an ask) */
/** `compacting`: a context fold between turns — no turn runs, but the kernel is busy and the page says so */
export type TurnState = "idle" | "running" | "waiting" | "compacting";

/** how many turns a thread opens on; the edge above them shows more on request */
export const HISTORY_WINDOW = 20;

/** the part of the thread above the window: how many turns wait there, and how to show them */
export type ThreadHistory = {
  hiddenTurns: number;
  showEarlier: (turns: number | "all") => void;
};

export type LongxRuntime = {
  runtime: AssistantRuntime;
  projectId: string;
  thread: ThreadRow | undefined;
  /** the route names a thread the project does not have */
  missing: boolean;
  view: ThreadView;
  /** the live views of the thread's sub-agents (and theirs), by kernel thread id */
  subviews: SubViews;
  ready: boolean;
  error: string | null;
  state: TurnState;
  history: ThreadHistory;
  /** why the thread cannot take messages, if so */
  disabledReason: string | null;
  /** the project's default model id, for the rail to name what a new chat starts on */
  defaultModelId: string | null;
  /** the model (and level) the project's description names — what a turn runs on when nobody picks one */
  definitionModel: { model: string | null; effort: string | null } | null;
  model: string | null;
  setModel: (slug: string | null) => void;
  /** the reasoning level for the next turn (null = the thread's current, or the model's default) */
  effort: string | null;
  setEffort: (effort: string | null) => void;
  /** a queued message into the running turn now (a steer) */
  insertQueued: (queueItemId: string) => Promise<void>;
  /** a message from elsewhere that waits for the turn to end, in now (立即插入) */
  releaseWaiting: (waitingId: string) => Promise<void>;
  /** words as the person's message (the stopped turn's 继续) */
  sendText: (text: string) => Promise<void>;
  /** the stopped last turn taken out of the thread (丢弃) — never into the composer */
  discardTurn: (kernelTurnId: string) => Promise<void>;
};

// voice input is wired (WebSpeechDictationAdapter, the mic in the composer rail)
// but off for now: flip this to show it again
const DICTATION = false;

// statuses that end a thread for good
const CLOSED = new Set(["unrecoverable", "archived"]);

const subagentIds = (view: ThreadView): string[] => [
  ...subagentsOf(view).keys(),
];

export function useLongxRuntime(opts: LongxRuntimeOptions): LongxRuntime {
  const {
    projectId,
    webSearch,
    defaultModelId = null,
    threadId,
    onOpenThread,
    onSignal,
  } = opts;
  const client = useQueryClient();
  const threads = useThreads(projectId);
  const rows = useMemo(
    () => (threads.data ?? []) as ThreadRow[],
    [threads.data],
  );
  const listed = threadId ? rows.find((t) => t.id === threadId) : undefined;
  // a sub-agent's row is not in the project's list: fetched by id for its own page
  const single = useThread(threadId !== undefined && !threads.isPending && !listed ? threadId : undefined);
  const thread = listed ?? (single.data as ThreadRow | undefined);
  // the project's description may name a model: the turn runs on it unless the person picks one
  const definition = useAgentDefinition(projectId);
  const definitionModel = useMemo(
    () => (definition.data ? { model: definition.data.model, effort: definition.data.effort } : null),
    [definition.data],
  );
  const { view, ready, error, refetch } = useThreadView(thread?.kernelThreadId, onSignal);
  // sub-agents work on their own threads; the parent's activities name
  // them, and a child's activities name its own children
  const subviews = useThreadViews(
    useMemo(() => subagentIds(view), [view]),
    subagentIds,
  );
  const [model, setModelState] = useState<string | null>(null);
  const [effort, setEffort] = useState<string | null>(null);
  const start = useStartThread(projectId);

  // the model and level choices are per thread (a new model starts on its
  // own default level)
  useEffect(() => {
    setModelState(null);
    setEffort(null);
  }, [threadId]);
  const setModel = useCallback((slug: string | null) => {
    setModelState(slug);
    setEffort(null);
  }, []);

  const invalidate = useCallback(
    () => client.invalidateQueries({ queryKey: queryKeys.threads(projectId) }),
    [client, projectId],
  );

  // a new chat starts with the project's web-search default and on the picked
  // model and level; `start` itself is a new object every render, its
  // mutateAsync is stable
  const startThread = start.mutateAsync;
  const createThread = useCallback(async (): Promise<ThreadTarget> => {
    const row = await startThread({
      ...(webSearch !== undefined ? { webSearch } : {}),
      ...(model ? { model } : {}),
      ...(effort ? { effort } : {}),
    });
    return { threadId: row.id, kernelThreadId: row.kernelThreadId };
  }, [startThread, webSearch, model, effort]);

  const threadList = useMemo(
    () =>
      buildThreadListAdapter({
        rows,
        currentId: threadId,
        loading: threads.isPending,
        actions: {
          switchTo: onOpenThread,
          // a new chat is the page without a thread: the first message creates
          // the row (a row per click left "未命名会话"s behind)
          create: async () => onOpenThread(null),
          rename: async (id, title) => {
            unwrap(await renameThread({ identity: id, input: { title } }));
            await invalidate();
          },
          archive: async (id) => {
            unwrap(await archiveThread({ identity: id }));
            await invalidate();
            if (id === threadId) onOpenThread(null);
          },
          delete: async (id) => {
            unwrap(await deleteThread({ input: { threadId: id } }));
            await invalidate();
            if (id === threadId) onOpenThread(null);
          },
        },
      }),
    [rows, threadId, threads.isPending, onOpenThread, invalidate],
  );

  // a message while a turn runs waits in assistant-ui's queue (the message-queue
  // element shows it above the composer) and goes out as a new turn when the
  // turn ends; `insertQueued` is its "insert now" (a steer). The queue runs
  // the latest adapter through a ref.
  const onNewRef = useRef<(message: AppendMessage) => Promise<void>>(async () => {});
  const [queue] = useState(() => createMessageQueue({ run: (message) => void onNewRef.current(message) }));
  // the store reads the queue's lanes when this component renders: a change
  // in the queue (a message added, taken back, dispatched) must render it
  // (the runtime only re-applies a *new* adapter object, so the version is a dependency of the memo below)
  const [queueVersion, queueChanged] = useReducer((n: number) => n + 1, 0);
  useEffect(() => {
    const source = queue as unknown as { subscribe?: (cb: () => void) => () => void };
    const adapter = queue.adapter as unknown as { subscribe?: (cb: () => void) => () => void };
    const unsubscribe = (source.subscribe ?? adapter.subscribe)?.(queueChanged);
    return () => unsubscribe?.();
  }, [queue]);
  const running = thread !== undefined && runningTurnId(view) !== null;
  const wasRunning = useRef(running);
  useEffect(() => {
    if (!wasRunning.current && running) queue.notifyBusy();
    if (wasRunning.current && !running) queue.notifyIdle();
    wasRunning.current = running;
  }, [running, queue]);
  const insertQueued = useCallback(
    async (queueItemId: string) => {
      // a send while running lands in the steer lane, a later move in the other
      const item = [...queue.adapter.steerItems, ...queue.adapter.items].find((i) => i.id === queueItemId);
      if (!item || !thread) return;
      const text = item.parts.flatMap((p) => (p.type === "text" ? [p.text] : [])).join("\n");
      const steered = await steerTurn({ fields: ["kernelTurnId"], input: { threadId: thread.id, text } });
      if (steered.success) {
        queue.adapter.remove(queueItemId);
        void invalidate();
      } else if (steered.errors.some((e) => e.message === "not_running")) {
        // the turn is over (a stop pauses assistant-ui's queue, so nothing would go out
        // by itself): the message goes out as a new turn now, off the queue
        queue.adapter.remove(queueItemId);
        unwrap(
          await sendMessage({
            fields: ["id"],
            input: { threadId: thread.id, text, ...(model ? { model } : {}), ...(effort ? { effort } : {}) },
          }),
        );
        void invalidate();
      } else {
        unwrap(steered);
      }
    },
    [queue, thread, invalidate, model, effort],
  );
  // a waiting message in now; one that went meanwhile (the turn ended and took
  // it up, another page sent it) is no error
  const releaseWaiting = useCallback(
    async (waitingId: string) => {
      if (!thread) return;
      const released = await releaseWaitingRpc({ input: { threadId: thread.id, waitingId } });
      if (!released.success && !released.errors.some((e) => e.message === "not_found")) unwrap(released);
    },
    [thread],
  );
  const sendText = useCallback(
    async (text: string) => {
      if (!thread) return;
      unwrap(
        await sendMessage({
          fields: ["id"],
          input: { threadId: thread.id, text, ...(model ? { model } : {}), ...(effort ? { effort } : {}) },
        }),
      );
      void invalidate();
    },
    [thread, model, effort, invalidate],
  );
  const discardTurn = useCallback(
    async (kernelTurnId: string) => {
      if (!thread) return;
      unwrap(await retractTurn({ fields: ["text"], input: { threadId: thread.id, kernelTurnId } }));
      void invalidate();
    },
    [thread, invalidate],
  );
  // what the composer can take: images (to the model as data urls), text
  // files (inlined) and any other file (uploaded to the server, its path in
  // the message), and the browser's speech recognition where it exists —
  // built once, like everything the adapter is made of
  const [attachments] = useState(
    () =>
      new CompositeAttachmentAdapter([
        new SimpleImageAttachmentAdapter(),
        new SimpleTextAttachmentAdapter(),
        new FileUploadAttachmentAdapter({ projectId, csrf: csrfToken }),
      ]),
  );
  const [dictation] = useState(() =>
    DICTATION && WebSpeechDictationAdapter.isSupported()
      ? new WebSpeechDictationAdapter({
          language: navigator.language,
          interimResults: true,
        })
      : undefined,
  );

  const disabledReason =
    thread && CLOSED.has(thread.status) ? thread.status : null;
  const target = thread
    ? { threadId: thread.id, kernelThreadId: thread.kernelThreadId }
    : null;
  const onSent = useCallback(
    (sent: ThreadTarget) => {
      void invalidate();
      if (sent.threadId !== threadId) onOpenThread(sent.threadId);
    },
    [invalidate, threadId, onOpenThread],
  );

  // a long thread opens on its tail; another thread starts over
  const [windowTurns, setWindowTurns] = useState(HISTORY_WINDOW);
  useEffect(() => setWindowTurns(HISTORY_WINDOW), [threadId]);
  const totalTurns = useMemo(() => turnCount(view), [view]);
  const history = useMemo<ThreadHistory>(
    () => ({
      hiddenTurns: Math.max(0, totalTurns - windowTurns),
      showEarlier: (turns) =>
        setWindowTurns((w) => (turns === "all" ? Number.MAX_SAFE_INTEGER : w + turns)),
    }),
    [totalTurns, windowTurns],
  );

  const adapter = useMemo(
    () =>
      buildAdapter({
        target,
        view,
        subviews,
        window: windowTurns,
        model,
        effort,
        disabled: disabledReason !== null,
        sendDisabled: thread !== undefined && !ready,
        loading: thread !== undefined && !ready && !error,
        createThread,
        onSent,
        refetch,
        threadList,
        queue: queue.adapter,
        attachments,
        dictation,
      }),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [
      target?.threadId,
      target?.kernelThreadId,
      view,
      subviews,
      windowTurns,
      model,
      effort,
      disabledReason,
      thread?.status,
      ready,
      error,
      createThread,
      onSent,
      refetch,
      threadList,
      queue,
      attachments,
      dictation,
      queueVersion,
    ],
  );
  onNewRef.current = adapter.onNew;
  const runtime = useExternalStoreRuntime(adapter);

  const awaiting =
    view.requests.length > 0 ||
    Object.values(subviews).some((v) => v.requests.length > 0);
  const state: TurnState =
    thread && awaiting
      ? "waiting"
      : thread && runningTurnId(view)
        ? "running"
        : thread && view.progress?.kind === "compaction"
          ? "compacting"
          : "idle";

  return {
    runtime,
    projectId,
    thread,
    missing:
      threadId !== undefined && !threads.isPending && thread === undefined && !single.isPending,
    view,
    subviews,
    ready,
    error,
    state,
    history,
    disabledReason,
    defaultModelId,
    definitionModel,
    model,
    setModel,
    effort,
    setEffort,
    insertQueued,
    releaseWaiting,
    sendText,
    discardTurn,
  };
}
