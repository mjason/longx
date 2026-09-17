// `useCodexRuntime`: one hook that turns a project + the thread in the
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
import { archiveThread, deleteThread, renameThread, steerTurn } from "@/ash_rpc";
import { queryKeys, unwrap, useAgentDefinition, useSkills, useStartThread, useThread, useThreads } from "@/core/projects";
import {
  CompositeAttachmentAdapter,
  SimpleImageAttachmentAdapter,
  SimpleTextAttachmentAdapter,
  WebSpeechDictationAdapter,
  createMessageQueue,
} from "@assistant-ui/react";
import {
  buildAdapter,
  type AccessMode,
  type DirtyChange,
  type DirtyDecision,
  type ThreadTarget,
} from "./adapter";
import { subagentsOf, type SubViews } from "./messages";
import { runningTurnId, type ThreadView } from "./thread";
import { csrfToken } from "@/core/rpcHooks";
import { FileUploadAttachmentAdapter } from "./fileAttachments";
import { buildThreadListAdapter, type ThreadRow } from "./threadList";
import { useThreadView } from "./useThreadView";
import { useThreadViews } from "./useThreadViews";

/** which kernel runs the project's threads: codex (sandbox, approvals) or Longx's own */
export type Engine = "codex" | "native";

export type CodexRuntimeOptions = {
  projectId: string;
  /** the project's engine; the native kernel has no access mode to pick */
  engine?: Engine;
  /** the project's defaults: what a new chat starts with */
  defaults: AccessMode;
  /** the project's own default model (a `Longx.AI.Model` id; null = the global default) */
  defaultModelId?: string | null;
  /** the thread row id from the route; undefined = new chat (the first message creates one) */
  threadId: string | undefined;
  /** navigate to a thread; null = the project's new chat (after the thread on screen is gone) */
  onOpenThread: (threadId: string | null) => void;
  onDirtyTree?: (changes: DirtyChange[]) => Promise<DirtyDecision>;
  /** a thread event worth telling the person about as it happens (model/rerouted) */
  onSignal?: (method: string, params: Record<string, unknown>) => void;
  /** a stop before anything came back: the message's text, to be put back in the composer */
  onRetract?: (text: string) => void;
};

export type TurnState = "idle" | "running" | "approval";

export type CodexRuntime = {
  runtime: AssistantRuntime;
  projectId: string;
  engine: Engine;
  thread: ThreadRow | undefined;
  /** the route names a thread the project does not have */
  missing: boolean;
  view: ThreadView;
  /** the live views of the thread's sub-agents (and theirs), by codex thread id */
  subviews: SubViews;
  ready: boolean;
  error: string | null;
  state: TurnState;
  /** why the thread cannot take messages, if so */
  disabledReason: string | null;
  /** the project's default model id, for the rail to name what a new chat starts on */
  defaultModelId: string | null;
  /** the native kernel: the model (and level) the project's description names — what a turn runs on when nobody picks one */
  definitionModel: { model: string | null; effort: string | null } | null;
  model: string | null;
  setModel: (slug: string | null) => void;
  /** the reasoning level for the next turn (null = the thread's current, or the model's default) */
  effort: string | null;
  setEffort: (effort: string | null) => void;
  /** the access mode the next turn runs with */
  mode: AccessMode;
  setMode: (mode: AccessMode) => void;
  /** a queued message into the running turn now (codex's steer) */
  insertQueued: (queueItemId: string) => Promise<void>;
};

// voice input is wired (WebSpeechDictationAdapter, the mic in the composer rail)
// but off for now: flip this to show it again
const DICTATION = false;

// statuses that end a thread for good vs. a codex on its way back
const CLOSED = new Set(["unrecoverable", "archived"]);

const subagentIds = (view: ThreadView): string[] => [
  ...subagentsOf(view).keys(),
];

export function useCodexRuntime(opts: CodexRuntimeOptions): CodexRuntime {
  const {
    projectId,
    engine = "codex",
    defaults,
    defaultModelId = null,
    threadId,
    onOpenThread,
    onDirtyTree,
    onSignal,
    onRetract,
  } = opts;
  const client = useQueryClient();
  const threads = useThreads(projectId);
  const skills = useSkills(projectId).data;
  const rows = useMemo(
    () => (threads.data ?? []) as ThreadRow[],
    [threads.data],
  );
  const listed = threadId ? rows.find((t) => t.id === threadId) : undefined;
  // a sub-agent's row is not in the project's list: fetched by id for its own page
  const single = useThread(threadId !== undefined && !threads.isPending && !listed ? threadId : undefined);
  const thread = listed ?? (single.data as ThreadRow | undefined);
  // the native kernel's description may name a model: the turn runs on it unless the person picks one
  const definition = useAgentDefinition(engine === "native" ? projectId : undefined);
  const definitionModel = useMemo(
    () => (engine === "native" && definition.data ? { model: definition.data.model, effort: definition.data.effort } : null),
    [engine, definition.data],
  );
  const { view, ready, error, refetch } = useThreadView(thread?.codexThreadId, onSignal);
  // sub-agents work on their own codex threads; the parent's activities name
  // them, and a child's activities name its own children
  const subviews = useThreadViews(
    useMemo(() => subagentIds(view), [view]),
    subagentIds,
  );
  const [model, setModelState] = useState<string | null>(null);
  const [effort, setEffort] = useState<string | null>(null);
  const start = useStartThread(projectId);

  // the model and level choices are per thread (a new model starts on its
  // own default level); the mode starts from what the thread runs with (the
  // row) and is only overridden by an explicit choice
  useEffect(() => {
    setModelState(null);
    setEffort(null);
  }, [threadId]);
  const setModel = useCallback((slug: string | null) => {
    setModelState(slug);
    setEffort(null);
  }, []);
  const [modeOverride, setModeOverride] = useState<{
    threadId: string | undefined;
    mode: AccessMode;
  } | null>(null);
  // referentially stable while nothing changes: assistant-ui re-applies the
  // adapter after every render, and an adapter rebuilt each time notifies
  // the store on every commit (a render loop once a subscriber re-renders us)
  const rowMode: AccessMode | null = useMemo(
    () =>
      thread
        ? {
            sandbox: thread.sandbox as AccessMode["sandbox"],
            approvalPolicy:
              thread.approvalPolicy as AccessMode["approvalPolicy"],
            networkAccess: thread.networkAccess ?? false,
            webSearch: thread.webSearch ?? true,
            multiAgent: thread.multiAgent ?? true,
            autoReview: thread.autoReview ?? true,
          }
        : null,
    [
      thread?.sandbox,
      thread?.approvalPolicy,
      thread?.networkAccess,
      thread?.webSearch,
      thread?.multiAgent,
      thread?.autoReview,
      thread !== undefined,
    ],
  );
  const mode =
    modeOverride && modeOverride.threadId === threadId
      ? modeOverride.mode
      : (rowMode ?? defaults);
  const setMode = useCallback(
    (next: AccessMode) => setModeOverride({ threadId, mode: next }),
    [threadId],
  );

  const invalidate = useCallback(
    () => client.invalidateQueries({ queryKey: queryKeys.threads(projectId) }),
    [client, projectId],
  );

  // a new chat starts in the mode picked in the rail (web search is start-only)
  // and on the picked model and level (start-time config: window, search mode);
  // `start` itself is a new object every render, its mutateAsync is stable
  const startThread = start.mutateAsync;
  const createThread = useCallback(async (): Promise<ThreadTarget> => {
    const row = await startThread({
      ...mode,
      ...(model ? { model } : {}),
      ...(effort ? { effort } : {}),
    });
    return { threadId: row.id, codexThreadId: row.codexThreadId };
  }, [startThread, mode, model, effort]);

  const threadList = useMemo(
    () =>
      buildThreadListAdapter({
        rows,
        currentId: threadId,
        loading: threads.isPending,
        actions: {
          switchTo: onOpenThread,
          // a new chat is the page without a thread: the first message creates
          // the row (a row per click left "未命名会话"s behind and started a
          // codex thread nobody used)
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
  // turn ends — what the Codex app does; `insertQueued` is its "insert now"
  // (turn/steer). The queue runs the latest adapter through a ref.
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
      const steered = await steerTurn({ fields: ["codexTurnId"], input: { threadId: thread.id, text } });
      if (steered.success) {
        queue.adapter.remove(queueItemId);
        void invalidate();
      } else if (!steered.errors.some((e) => e.message === "not_running")) {
        unwrap(steered);
      }
      // not_running: the turn ended meanwhile; the queue sends it as a new turn
    },
    [queue, thread, invalidate],
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
    ? { threadId: thread.id, codexThreadId: thread.codexThreadId }
    : null;
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
        subviews,
        model,
        effort,
        mode,
        disabled: disabledReason !== null,
        sendDisabled:
          thread?.status === "disconnected" || (thread !== undefined && !ready),
        loading: thread !== undefined && !ready && !error,
        createThread,
        onSent,
        onDirtyTree,
        onRetract,
        refetch,
        threadList,
        queue: queue.adapter,
        attachments,
        dictation,
        ...(skills ? { skills } : {}),
      }),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [
      target?.threadId,
      target?.codexThreadId,
      view,
      subviews,
      model,
      effort,
      mode,
      disabledReason,
      thread?.status,
      ready,
      error,
      createThread,
      onSent,
      onDirtyTree,
      onRetract,
      refetch,
      threadList,
      queue,
      attachments,
      dictation,
      skills,
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
      ? "approval"
      : thread && runningTurnId(view)
        ? "running"
        : "idle";

  return {
    runtime,
    projectId,
    engine,
    thread,
    missing:
      threadId !== undefined && !threads.isPending && thread === undefined && !single.isPending,
    view,
    subviews,
    ready,
    error,
    state,
    disabledReason,
    defaultModelId,
    definitionModel,
    model,
    setModel,
    effort,
    setEffort,
    mode,
    setMode,
    insertQueued,
  };
}
