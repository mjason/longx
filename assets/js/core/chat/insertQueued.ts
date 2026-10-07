import { sendMessage, steerTurn } from "@/core/api";
import { unwrap } from "@/core/projects";
import { inputOf, type ThreadTarget } from "./adapter";
import type { PendingApi } from "./pending";
import type { QueuedMessages } from "./queuedMessages";

type InsertOptions = {
  target: ThreadTarget;
  after: number;
  model: string | null;
  effort: string | null;
  pending: PendingApi;
  invalidate: () => Promise<unknown>;
};

/** Same payload as an ordinary send; the queue stays retryable until accepted. */
export async function insertQueuedMessage(queue: QueuedMessages, id: string, opts: InsertOptions) {
  const original = queue.getOriginal(id);
  if (!original || queue.inserting.has(id)) return;
  queue.inserting.add(id);
  const { text, images } = inputOf(original);
  const { target, pending } = opts;
  const echo = pending.add({
    ...target, text, images, kind: "steer", after: opts.after,
  });
  const input = { threadId: target.threadId, text, ...(images.length ? { images } : {}) };
  try {
    const steered = await steerTurn({ input });
    if (!steered.success && steered.errors.some((e) => e.message === "not_running")) {
      pending.update(echo, { kind: "message" });
      unwrap(await sendMessage({
        input: { ...input, ...(opts.model ? { model: opts.model } : {}), ...(opts.effort ? { effort: opts.effort } : {}) },
      }));
    } else {
      unwrap(steered);
    }
    queue.adapter.remove(id);
    void opts.invalidate();
  } catch (error) {
    // The UI invokes insertion fire-and-forget. Show the failure in its echo,
    // keep the full queue item for retry, and do not leak an unhandled rejection.
    pending.update(echo, { error: error instanceof Error ? error.message : String(error) });
  } finally {
    queue.inserting.delete(id);
  }
}
