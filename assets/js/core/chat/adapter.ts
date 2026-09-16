// The assistant-ui ExternalStoreAdapter for a Longx thread: the app owns
// the messages (ThreadView → toMessages); the runtime calls back into our
// RPCs for sending, stopping and answering approvals / questions. UI
// features are handler-driven (assistant-ui): a handler that is present
// turns its button on, so only what codex can do is wired here.
import type {
  AppendMessage,
  AttachmentAdapter,
  DictationAdapter,
  ExternalStoreAdapter,
  ExternalStoreThreadListAdapter,
  ExternalThreadQueueAdapter,
  ThreadMessageLike,
} from "@assistant-ui/react";
import { answerRequest, approveReview, interruptTurn, respond, retractTurn, sendMessage, setGoal } from "@/ash_rpc";
import { skillsIn, type SkillRef } from "./mentions";
import { RpcFailure, unwrap } from "@/core/projects";
import {
  requestIdFor,
  toMessages,
  type ApprovalDecision,
  type SubViews,
} from "./messages";
import { runningTurnId, type ThreadView } from "./thread";

export type ThreadTarget = { threadId: string; codexThreadId: string };

export type DirtyChange = { path: string; status: string };

/** The access mode codex runs a turn with; codex keeps it for the turns after. */
export type AccessMode = {
  sandbox: "read_only" | "workspace_write" | "danger_full_access";
  approvalPolicy: "never" | "on_request" | "untrusted" | "auto_accept";
  networkAccess: boolean;
  /** codex's web.run (search + open URL, run by Longx, not the sandbox); fixed at thread start */
  webSearch: boolean;
  /** codex's sub-agent tools (spawn / wait / …); fixed at thread start */
  multiAgent: boolean;
  /** codex's automatic approval review (Guardian) instead of a card; fixed at thread start */
  autoReview: boolean;
};
/** what to do with uncommitted changes when the project's policy is "ask"; null = don't send */
export type DirtyDecision = "commit" | "ignore" | null;

/** What renderers reach through `useAuiState((s) => s.thread.extras)`. */
export type CodexExtras = {
  /** answers a requestUserInput: question id → the chosen answers */
  answerRequest: (
    requestId: string,
    answers: Record<string, string[]>,
  ) => Promise<void>;
  /** overrides a denial of codex's automatic approval review (the person allows the action) */
  approveDeniedReview: (reviewId: string) => Promise<void>;
};

export type AdapterOptions = {
  /** null = no thread open yet: the first message creates one (`createThread`) */
  target: ThreadTarget | null;
  view: ThreadView;
  /** the live views of the thread's sub-agents (nested conversations; their approvals surface here) */
  subviews?: SubViews;
  /** the model slug for the next turn (null = the thread's current) */
  model: string | null;
  /** the reasoning level for the next turn (null = the thread's current / the model's default) */
  effort?: string | null;
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
  /** files staged in the composer (images → codex image inputs, text files → text) */
  attachments?: AttachmentAdapter;
  /** voice input written into the composer (the browser's speech recognition) */
  dictation?: DictationAdapter;
  /** the project's skills: a `$name` in the text rides on the turn as a skill input */
  skills?: readonly SkillRef[];
  /** a stop before anything came back took the turn out; its text comes back to the composer */
  onRetract?: (text: string) => void;
};

export function textOf(message: AppendMessage): string {
  return message.content
    .map((part) => (part.type === "text" ? part.text : ""))
    .join("")
    .trim();
}

/** What a message carries for codex: the typed text plus any text attachments, and the images as data urls. */
export function inputOf(message: AppendMessage): {
  text: string;
  images: string[];
} {
  const images: string[] = [];
  const texts: string[] = [];
  for (const attachment of message.attachments ?? []) {
    for (const part of attachment.content ?? []) {
      if (part.type === "image") images.push(part.image);
      else if (part.type === "text") texts.push(part.text);
    }
  }
  const text = [textOf(message), ...texts]
    .filter((t) => t.length > 0)
    .join("\n\n");
  return { text, images };
}

/** Words are no side effect: thinking and a half-said answer go with a retracted turn. */
const HARMLESS_ITEMS = new Set(["userMessage", "agentMessage", "reasoning", "plan"]);

/**
 * Whether the turn ran anything — a command, a patch, a tool, a search, a
 * sub-agent — or waits to (an approval or a question pending): then a revert
 * cannot take it back, and a stop is only an interrupt.
 */
export function turnHadEffects(view: ThreadView, turnId: string): boolean {
  return (
    view.items.some((i) => i.turnId === turnId && !HARMLESS_ITEMS.has(i.type)) ||
    view.requests.some((r) => r.params["turnId"] === turnId)
  );
}

export function buildAdapter(
  opts: AdapterOptions,
): ExternalStoreAdapter<ThreadMessageLike> {
  const { view } = opts;
  const threadId = () => opts.target?.threadId;
  const extras: CodexExtras = {
    answerRequest: async (requestId, answers) => {
      const id = threadId();
      if (!id) return;
      const shaped = Object.fromEntries(
        Object.entries(answers).map(([q, a]) => [q, { answers: a }]),
      );
      unwrap(
        await answerRequest({
          input: { threadId: id, requestId, answers: shaped },
        }),
      );
    },
    approveDeniedReview: async (reviewId) => {
      const id = threadId();
      if (!id) return;
      unwrap(await approveReview({ input: { threadId: id, reviewId } }));
    },
  };
  return {
    messages: opts.target ? toMessages(view, opts.subviews) : [],
    convertMessage: (m) => m,
    isRunning: opts.target ? runningTurnId(view) !== null : false,
    isDisabled: opts.disabled ?? false,
    isSendDisabled: opts.sendDisabled ?? false,
    ...(opts.loading !== undefined ? { isLoading: opts.loading } : {}),
    extras,
    adapters: {
      ...(opts.threadList ? { threadList: opts.threadList } : {}),
      ...(opts.attachments ? { attachments: opts.attachments } : {}),
      ...(opts.dictation ? { dictation: opts.dictation } : {}),
    },
    ...(opts.queue ? { queue: opts.queue } : {}),
    ...(opts.refetch ? { onRefetchThread: opts.refetch } : {}),
    onNew: async (message) => {
      const { text, images } = inputOf(message);
      if (!text && images.length === 0) return;
      const skills = skillsIn(text, opts.skills ?? []);
      let target = opts.target;
      if (!target) {
        if (!opts.createThread) throw new Error("no thread to send to");
        target = await opts.createThread();
      }
      // `/goal <objective>` typed past the command popover: the goal, not a message
      const goal = text.match(/^\/goal\s+(\S[\s\S]*)$/);
      if (goal) {
        unwrap(
          await setGoal({
            fields: ["objective", "status"],
            input: { threadId: target.threadId, objective: goal[1]!.trim() },
          }),
        );
        opts.onSent?.(target);
        return;
      }
      const send = (dirty?: "commit" | "ignore") =>
        sendMessage({
          fields: ["id"],
          input: {
            threadId: target.threadId,
            text,
            ...(images.length > 0 ? { images } : {}),
            ...(skills.length > 0 ? { skills } : {}),
            ...(opts.model ? { model: opts.model } : {}),
            ...(opts.effort ? { effort: opts.effort } : {}),
            ...(opts.mode
              ? {
                  sandbox: opts.mode.sandbox,
                  approvalPolicy: opts.mode.approvalPolicy,
                  networkAccess: opts.mode.networkAccess,
                }
              : {}),
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
      // nothing ran yet: take the turn back, the text returns to the composer
      if (!turnHadEffects(view, turnId) && opts.onRetract) {
        const { text } = unwrap(
          await retractTurn({ fields: ["text"], input: { threadId: id, codexTurnId: turnId } }),
        );
        opts.onRetract(text);
        return;
      }
      unwrap(
        await interruptTurn({ input: { threadId: id, codexTurnId: turnId } }),
      );
    },
    onRespondToToolApproval: async ({ approvalId, optionId, approved }) => {
      const id = threadId();
      if (!id) return;
      const decision =
        (optionId as ApprovalDecision | undefined) ??
        (approved ? "accept" : "decline");
      unwrap(
        await respond({
          input: {
            threadId: id,
            requestId: String(requestIdFor(view, approvalId)),
            decision,
          },
        }),
      );
    },
  };
}

function dirtyChanges(error: unknown): DirtyChange[] | null {
  if (!(error instanceof RpcFailure)) return null;
  const dirty = error.errors.find((e) => e.type === "dirty_tree");
  if (!dirty) return null;
  const changes = (dirty.details as { changes?: DirtyChange[] } | undefined)
    ?.changes;
  return Array.isArray(changes) ? changes : [];
}
