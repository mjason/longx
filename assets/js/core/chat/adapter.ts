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
import { answerRequest, interruptTurn, retractTurn, sendMessage, setGoal, steerTurn } from "@/core/api";
import { unwrap } from "@/core/projects";
import { toMessages, type SubViews } from "./messages";
import type { PendingApi } from "./pending";
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
  /** a stop before the model answered took the person's turn out: its text goes back to the composer */
  onRetract?: (text: string) => void;
  /** where a send registers its echo (core/chat/pending; the page draws them after the messages — never in this list, see there) */
  pendingApi?: PendingApi;
  /** a send that failed: no turn will end, so the queue must be told it is idle again */
  onSendFailed?: () => void;
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

/**
 * Whether the model has answered: said words (an assistant message with
 * text — one just begun, still empty, has not), run anything, or asked.
 * Thinking is no answer: a turn stopped while the model only reasoned is
 * taken back whole.
 */
export function turnAnswered(view: ThreadView, turnId: string): boolean {
  return (
    view.items.some((i) => i.turnId === turnId && (i.type === "agentMessage" ? String(i["text"] ?? "") !== "" : i.type !== "userMessage" && i.type !== "reasoning")) ||
    view.requests.some((r) => r.params["turnId"] === turnId)
  );
}

/** The person's own turn: its opening message is not another agent's, a job's, a watch's or the goal's. */
export function startedByPerson(view: ThreadView, turnId: string): boolean {
  const opening = view.items.find((i) => i.turnId === turnId && i.type === "userMessage");
  return opening !== undefined && !opening["from"] && !opening["origin"];
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
      // `/goal <objective>` typed past the command popover: the goal, not a message
      const goal = text.match(/^\/goal\s+(\S[\s\S]*)$/);
      // a turn in flight: the message goes into it (a steer — the kernel folds
      // it in at its next step); a turn that ended meanwhile is "not_running"
      // and the message a new turn
      const running = runningTurnId(view);
      // the echo before any round trip: the thread shows the message at once
      const echo = goal
        ? null
        : (opts.pendingApi?.add({
            threadId: opts.target?.threadId ?? null,
            kernelThreadId: opts.target?.kernelThreadId ?? null,
            text,
            images,
            kind: running && opts.target ? "steer" : "message",
            after: view.items.length,
          }) ?? null);
      try {
        let target = opts.target;
        if (!target) {
          if (!opts.createThread) throw new Error("no thread to send to");
          target = await opts.createThread();
          if (echo !== null) opts.pendingApi?.update(echo, { threadId: target.threadId, kernelThreadId: target.kernelThreadId });
        }
        if (goal) {
          unwrap(
            await setGoal({
              input: { threadId: target.threadId, objective: goal[1]!.trim() },
            }),
          );
          opts.onSent?.(target);
          return;
        }
        if (running && target.threadId === opts.target?.threadId) {
          const steered = await steerTurn({
            input: { threadId: target.threadId, text, ...(images.length > 0 ? { images } : {}) },
          });
          if (steered.success) {
            opts.onSent?.(target);
            return;
          }
          if (!steered.errors.some((e) => e.message === "not_running")) unwrap(steered);
          if (echo !== null) opts.pendingApi?.update(echo, { kind: "message" });
        }
        unwrap(
          await sendMessage({
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
      } catch (e) {
        opts.onSendFailed?.();
        // the echo stays, in red, with why it did not go — that is the error's
        // display; a rejection out of here would only be an unhandled one (the
        // queue runs onNew and forgets the promise)
        if (echo !== null) {
          opts.pendingApi?.update(echo, { error: e instanceof Error ? e.message : String(e) });
          return;
        }
        throw e;
      }
    },
    // a stop before the model answered (thinking is no answer) takes the
    // person's own turn back, as Claude Code does, and its text returns to the
    // composer for editing; once the model has answered — or for a turn another
    // agent, a job or a watch started (a take-back once put "[agent coder] …",
    // a child's report, in the person's composer) — a stop only interrupts:
    // the turn stays with its stopped-run card (继续 / 丢弃)
    onCancel: async () => {
      const turnId = runningTurnId(view);
      const id = threadId();
      if (!turnId || !id) return;
      if (opts.onRetract && startedByPerson(view, turnId) && !turnAnswered(view, turnId)) {
        const taken = await retractTurn({ input: { threadId: id, kernelTurnId: turnId } });
        if (taken.success) {
          opts.onRetract(taken.data.text);
          return;
        }
        // the model answered while the stop was on its way (has_output): an interrupt then
      }
      const stopped = await interruptTurn({ input: { threadId: id, kernelTurnId: turnId } });
      // "not_running": the turn ended on its own while the stop was on its way
      if (!stopped.success && !stopped.errors.some((e) => e.message === "not_running")) unwrap(stopped);
    },
  };
}

