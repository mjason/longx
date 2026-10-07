import type { AppendMessage } from "@assistant-ui/react";
import { sendMessageBatch } from "@/core/api";
import { unwrap } from "@/core/projects";
import { inputOf, type ThreadTarget } from "./adapter";
import type { PendingApi } from "./pending";

/** One request, separate inputs and echoes: later instructions do not overwrite earlier ones. */
export async function sendQueuedBatch(messages: AppendMessage[], options: {
  target: ThreadTarget;
  model: string | null;
  effort: string | null;
  pending: PendingApi;
  after: number;
}) {
  const inputs = messages.map(inputOf);
  const echoes = inputs.map((input, index) => options.pending.add({
    ...options.target, ...input, kind: index === 0 ? "message" : "steer", after: options.after,
  }));
  try {
    unwrap(await sendMessageBatch({
      input: {
        threadId: options.target.threadId,
        messages: inputs,
        ...(options.model ? { model: options.model } : {}),
        ...(options.effort ? { effort: options.effort } : {}),
      },
    }));
  } catch (error) {
    echoes.forEach(id => options.pending.update(id, { error: error instanceof Error ? error.message : String(error) }));
    // The queue catches this to restore the entire failed batch, paused.
    throw error;
  }
}
