// The assistant-ui ExternalStoreAdapter for a Longx thread: the app owns
// the messages (ThreadView → toMessages); the runtime calls back into our
// RPCs for sending, stopping and answering approvals.
import type { AppendMessage, ExternalStoreAdapter, ThreadMessageLike } from "@assistant-ui/react";
import { interruptTurn, respond, sendMessage } from "@/ash_rpc";
import { RpcFailure, unwrap } from "@/core/projects";
import { requestIdFor, toMessages, type ApprovalDecision } from "./messages";
import { runningTurnId, type ThreadView } from "./thread";

export type ThreadTarget = { threadId: string; codexThreadId: string };

export type DirtyChange = { path: string; status: string };
/** what to do with uncommitted changes when the project's policy is "ask"; null = don't send */
export type DirtyDecision = "commit" | "ignore" | null;

export type AdapterOptions = {
  target: ThreadTarget;
  view: ThreadView;
  /** the model slug for the next turn (null = the thread's current) */
  model: string | null;
  /** the thread cannot take messages (unrecoverable / archived / disconnected) */
  disabled?: boolean;
  onSent?: () => void;
  /** the project's dirty_start is :ask and the tree is dirty — ask the person */
  onDirtyTree?: (changes: DirtyChange[]) => Promise<DirtyDecision>;
};

export function textOf(message: AppendMessage): string {
  return message.content
    .map((part) => (part.type === "text" ? part.text : ""))
    .join("")
    .trim();
}

export function buildAdapter(opts: AdapterOptions): ExternalStoreAdapter<ThreadMessageLike> {
  const { target, view } = opts;
  return {
    messages: toMessages(view),
    convertMessage: (m) => m,
    isRunning: runningTurnId(view) !== null,
    isDisabled: opts.disabled ?? false,
    onNew: async (message) => {
      const text = textOf(message);
      if (!text) return;
      const send = (dirty?: "commit" | "ignore") =>
        sendMessage({
          fields: ["id"],
          input: { threadId: target.threadId, text, ...(opts.model ? { model: opts.model } : {}), ...(dirty ? { dirty } : {}) },
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
      opts.onSent?.();
    },
    onCancel: async () => {
      const turnId = runningTurnId(view);
      if (!turnId) return;
      unwrap(await interruptTurn({ input: { threadId: target.threadId, codexTurnId: turnId } }));
    },
    onRespondToToolApproval: async ({ approvalId, optionId, approved }) => {
      const decision = (optionId as ApprovalDecision | undefined) ?? (approved ? "accept" : "decline");
      unwrap(
        await respond({
          input: { threadId: target.threadId, requestId: String(requestIdFor(view, approvalId)), decision },
        }),
      );
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
