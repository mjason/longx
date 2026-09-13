// The assistant-ui ExternalStoreAdapter for a Longx thread: the app owns
// the messages (ThreadView → toMessages); the runtime calls back into our
// RPCs for sending, stopping and answering approvals / questions. UI
// features are handler-driven (assistant-ui): a handler that is present
// turns its button on, so only what codex can do is wired here.
import type {
  AppendMessage,
  ExternalStoreAdapter,
  ExternalStoreThreadListAdapter,
  ExternalThreadQueueAdapter,
  ThreadMessageLike,
} from "@assistant-ui/react";
import { answerRequest, interruptTurn, respond, sendMessage } from "@/ash_rpc";
import { RpcFailure, unwrap } from "@/core/projects";
import { requestIdFor, toMessages, type ApprovalDecision } from "./messages";
import { runningTurnId, type ThreadView } from "./thread";

export type ThreadTarget = { threadId: string; codexThreadId: string };

export type DirtyChange = { path: string; status: string };

/** The access mode codex runs a turn with; codex keeps it for the turns after. */
export type AccessMode = {
  sandbox: "read_only" | "workspace_write" | "danger_full_access";
  approvalPolicy: "never" | "on_request" | "untrusted";
  networkAccess: boolean;
  /** codex's web.run (search + open URL, run by Longx, not the sandbox); fixed at thread start */
  webSearch: boolean;
};
/** what to do with uncommitted changes when the project's policy is "ask"; null = don't send */
export type DirtyDecision = "commit" | "ignore" | null;

/** What renderers reach through `useAuiState((s) => s.thread.extras)`. */
export type CodexExtras = {
  /** answers a requestUserInput: question id → the chosen answers */
  answerRequest: (requestId: string, answers: Record<string, string[]>) => Promise<void>;
};

export type AdapterOptions = {
  /** null = no thread open yet: the first message creates one (`createThread`) */
  target: ThreadTarget | null;
  view: ThreadView;
  /** the model slug for the next turn (null = the thread's current) */
  model: string | null;
  /** the access mode for the next turn (undefined = the thread's current) */
  mode?: AccessMode;
  /** the thread cannot take messages at all (unrecoverable / archived) */
  disabled?: boolean;
  /** typing is fine, sending is not (codex reconnecting) */
  sendDisabled?: boolean;
  /** the snapshot has not arrived yet */
  loading?: boolean;
  createThread?: () => Promise<ThreadTarget>;
  onSent?: (target: ThreadTarget) => void;
  /** the project's dirty_start is :ask and the tree is dirty — ask the person */
  onDirtyTree?: (changes: DirtyChange[]) => Promise<DirtyDecision>;
  /** re-pull the snapshot in place (threads.reloadMainThread) */
  refetch?: () => Promise<void>;
  threadList?: ExternalStoreThreadListAdapter;
  queue?: ExternalThreadQueueAdapter;
};

export function textOf(message: AppendMessage): string {
  return message.content
    .map((part) => (part.type === "text" ? part.text : ""))
    .join("")
    .trim();
}

export function buildAdapter(opts: AdapterOptions): ExternalStoreAdapter<ThreadMessageLike> {
  const { view } = opts;
  const threadId = () => opts.target?.threadId;
  const extras: CodexExtras = {
    answerRequest: async (requestId, answers) => {
      const id = threadId();
      if (!id) return;
      const shaped = Object.fromEntries(Object.entries(answers).map(([q, a]) => [q, { answers: a }]));
      unwrap(await answerRequest({ input: { threadId: id, requestId, answers: shaped } }));
    },
  };
  return {
    messages: opts.target ? toMessages(view) : [],
    convertMessage: (m) => m,
    isRunning: opts.target ? runningTurnId(view) !== null : false,
    isDisabled: opts.disabled ?? false,
    isSendDisabled: opts.sendDisabled ?? false,
    ...(opts.loading !== undefined ? { isLoading: opts.loading } : {}),
    extras,
    ...(opts.threadList ? { adapters: { threadList: opts.threadList } } : {}),
    ...(opts.queue ? { queue: opts.queue } : {}),
    ...(opts.refetch ? { onRefetchThread: opts.refetch } : {}),
    onNew: async (message) => {
      const text = textOf(message);
      if (!text) return;
      let target = opts.target;
      if (!target) {
        if (!opts.createThread) throw new Error("no thread to send to");
        target = await opts.createThread();
      }
      const send = (dirty?: "commit" | "ignore") =>
        sendMessage({
          fields: ["id"],
          input: {
            threadId: target.threadId,
            text,
            ...(opts.model ? { model: opts.model } : {}),
            ...(opts.mode ? { sandbox: opts.mode.sandbox, approvalPolicy: opts.mode.approvalPolicy, networkAccess: opts.mode.networkAccess } : {}),
            ...(dirty ? { dirty } : {}),
          },
        });
      try {
        unwrap(await send());
      } catch (error) {
        const changes = dirtyChanges(error);
        if (!changes || !opts.onDirtyTree) throw error;
        const decision = await opts.onDirtyTree(changes);
        if (!decision) return;
        unwrap(await send(decision));
      }
      opts.onSent?.(target);
    },
    onCancel: async () => {
      const turnId = runningTurnId(view);
      const id = threadId();
      if (!turnId || !id) return;
      unwrap(await interruptTurn({ input: { threadId: id, codexTurnId: turnId } }));
    },
    onRespondToToolApproval: async ({ approvalId, optionId, approved }) => {
      const id = threadId();
      if (!id) return;
      const decision = (optionId as ApprovalDecision | undefined) ?? (approved ? "accept" : "decline");
      unwrap(await respond({ input: { threadId: id, requestId: String(requestIdFor(view, approvalId)), decision } }));
    },
  };
}

function dirtyChanges(error: unknown): DirtyChange[] | null {
  if (!(error instanceof RpcFailure)) return null;
  const dirty = error.errors.find((e) => e.type === "dirty_tree");
  if (!dirty) return null;
  const changes = (dirty.details as { changes?: DirtyChange[] } | undefined)?.changes;
  return Array.isArray(changes) ? changes : [];
}
