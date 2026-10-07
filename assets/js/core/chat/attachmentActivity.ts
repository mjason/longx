import type { AttachmentAdapter, PendingAttachment } from "@assistant-ui/react";
import { isGenerator, type Added } from "./attachments";

/** Track adds even before an async upload has produced its first chip. */
export function trackAttachmentActivity(adapter: AttachmentAdapter, changed: (count: number) => void): AttachmentAdapter {
  let pending = 0;
  const start = () => changed(++pending);
  const finish = () => changed(--pending);
  async function* steps(added: AsyncGenerator<PendingAttachment, void>) {
    try { yield* added; }
    finally { finish(); }
  }
  return {
    accept: adapter.accept,
    add(state): Added {
      start();
      try {
        const added = adapter.add(state);
        return isGenerator(added) ? steps(added) : added.finally(finish);
      } catch (error) {
        finish();
        throw error;
      }
    },
    async send(attachment) {
      start();
      try { return await adapter.send(attachment); }
      finally { finish(); }
    },
    remove: attachment => adapter.remove(attachment),
  };
}
