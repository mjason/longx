// The assistant-ui ExternalStoreAdapter for a Longx thread: the app owns
// the messages (ThreadView → toMessages); the runtime calls back into our
// RPCs for sending, stopping and answering a tool's asks. UI features are
// handler-driven (assistant-ui): a handler that is present turns its
// button on, so only what the kernel can do is wired here.
import type {
  AppendMessage,
  AttachmentAdapter,
  DictationAdapter,
  ExternalStoreAdapter,
  ExternalStoreThreadListAdapter,
    ThreadMessageLike,
} from "@assistant-ui/react";
import { answerRequest, interruptTurn, retractTurn, sendMessage, setGoal, steerTurn } from "@/ash_rpc";
import { unwrap } from "@/core/projects";
import { toMessages, type SubViews } from "./messages";
import type { ExternalThreadQueueAdapter } from "@assistant-ui/react";
import { runningTurnId, type ThreadView } from "./thread";

export type ThreadTarget = { threadId: string; kernelThreadId: string };

/** What renderers reach through `useAuiState((s) => s.thread.extras)`. */
export type ThreadExtras = {
  /** answers the kernel's ask (Context.ask) as it is: {done: true}, {cancelled: true}, or the fields typed */
  answerAction: (requestId: string, answers: Record<string, unknown>) => Promise<void>;
};

export type AdapterOptions = {
  /** what lets the composer send while a turn runs (`createSteerQueue`): holds nothing */
  queue?: ExternalThreadQueueAdapter;
  /** null = no thread open yet: the first message creates one (`createThread`) */
  target: ThreadTarget | null;
  view: ThreadView;
  /** the live views of the thread's sub-agents (nested conversations; their asks surface here) */
  subviews?: SubViews;
  /** the model slug for the next turn (null = the thread's current) */
  model: string | null;
  /** the reasoning level for the next turn (null = the thread's current / the model's default) */
  effort?: string | null;
  /** the thread cannot take messages at all (unrecoverable / archived) */
  disabled?: boolean;
  /** typing is fine, sending is not (the view not loaded yet) */
  sendDisabled?: boolean;
  /** the snapshot has not arrived yet */
  loading?: boolean;
  createThread?: () => Promise<ThreadTarget>;
  onSent?: (target: ThreadTarget) => void;
  /** re-pull the snapshot in place (threads.reloadMainThread) */
  refetch?: () => Promise<void>;
  threadList?: ExternalStoreThreadListAdapter;
  /** files staged in the composer (images → image inputs, text files → text) */
  attachments?: AttachmentAdapter;
  /** voice input written into the composer (the browser's speech recognition) */
  dictation?: DictationAdapter;
  /** a stop before anything came back took the turn out; its text comes back to the composer */
  onRetract?: (text: string) => void;
};

export function textOf(message: AppendMessage): string {
  return message.content
    .map((part) => (part.type === "text" ? part.text : ""))
    .join("")
    .trim();
}

/** What a message carries for the model: the typed text plus any text attachments, and the images as data urls. */
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
const HARMLESS_ITEMS = new Set(["userMessage", "agentMessage", "reasoning"]);

/**
 * Whether the turn ran anything — a command, a patch, a tool, a search, a
 * sub-agent — or waits to (an ask pending): then a revert cannot take it
 * back, and a stop is only an interrupt.
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
  const extras: ThreadExtras = {
    answerAction: async (requestId, answers) => {
      const id = threadId();
      if (!id) return;
      unwrap(await answerRequest({ input: { threadId: id, requestId, answers } }));
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
    ...(opts.refetch ? { onRefetchThread: opts.refetch } : {}),
    ...(opts.queue ? { queue: opts.queue } : {}),
    onNew: async (message) => {
      const { text, images } = inputOf(message);
      if (!text && images.length === 0) return;
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
      // a turn in flight: the message goes into it (a steer — the kernel folds
      // it in at its next step); a turn that ended meanwhile is "not_running"
      // and the message a new turn
      const running = runningTurnId(view);
      if (running && target.threadId === opts.target?.threadId) {
        const steered = await steerTurn({
          fields: ["kernelTurnId"],
          input: { threadId: target.threadId, text, ...(images.length > 0 ? { images } : {}) },
        });
        if (steered.success) {
          opts.onSent?.(target);
          return;
        }
        if (!steered.errors.some((e) => e.message === "not_running")) unwrap(steered);
      }
      unwrap(
        await sendMessage({
          fields: ["id"],
          input: {
            threadId: target.threadId,
            text,
            ...(images.length > 0 ? { images } : {}),
            ...(opts.model ? { model: opts.model } : {}),
            ...(opts.effort ? { effort: opts.effort } : {}),
          },
        }),
      );
      opts.onSent?.(target);
    },
    onCancel: async () => {
      const turnId = runningTurnId(view);
      const id = threadId();
      if (!turnId || !id) return;
      // nothing ran yet: take the turn back, the text returns to the composer
      if (!turnHadEffects(view, turnId) && opts.onRetract) {
        const { text } = unwrap(
          await retractTurn({ fields: ["text"], input: { threadId: id, kernelTurnId: turnId } }),
        );
        opts.onRetract(text);
        return;
      }
      unwrap(
        await interruptTurn({ input: { threadId: id, kernelTurnId: turnId } }),
      );
    },
  };
}

