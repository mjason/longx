// What the composer's attachment adapter says when a file fails. assistant-ui
// puts the message back in the composer and rethrows (the legacy composer)
// or logs (the store one) — either way the person saw nothing: a 251 KB
// text file the browser refused to read (FileReader's NotReadableError:
// changed after it was picked, or on a share it cannot read) bounced four
// times as "Uncaught (in promise) ProgressEvent" and nothing else. This
// wrapper reports every failed add or send in words, by file name, and
// lets the failure go on so the composer keeps its own recovery. DOM-free:
// the report is a callback (a toast on the page).
import type { AttachmentAdapter, CompleteAttachment, PendingAttachment } from "@assistant-ui/react";
import { t } from "@/ui/strings";

/** the DOMException a FileReader's error event carries, if that is what this is */
function readerError(error: unknown): { name: string } | null {
  const target = (error as { target?: { error?: unknown } } | null)?.target;
  const inner = target?.error as { name?: unknown } | undefined;
  return inner && typeof inner.name === "string" ? { name: inner.name } : null;
}

/** One line for the person about a file that could not be added or sent. */
export function describeAttachmentError(name: string, error: unknown): string {
  const reader = readerError(error);
  if (reader?.name === "NotReadableError") return t.attachmentUnreadable(name);
  if (reader) return t.attachmentFailed(name, reader.name);
  const why = error instanceof Error ? error.message : String(error);
  return t.attachmentFailed(name, why);
}

/** what an adapter's `add` answers: the attachment, or a stream of its progress */
export type Added = ReturnType<AttachmentAdapter["add"]>;

export const isGenerator = (added: Added): added is AsyncGenerator<PendingAttachment, void> =>
  typeof (added as AsyncGenerator<PendingAttachment, void>)[Symbol.asyncIterator] === "function";

// an adapter may add as a stream of progress (an async generator): the report
// rides on its failure the same way
async function* reportingGenerator(added: AsyncGenerator<PendingAttachment, void>, name: string, report: (message: string) => void) {
  try {
    for await (const step of added) yield step;
  } catch (error) {
    report(describeAttachmentError(name, error));
    throw error;
  }
}

/** The adapter, with every failure told to `report` before it goes on to the composer. */
export function reportingAdapter(adapter: AttachmentAdapter, report: (message: string) => void): AttachmentAdapter {
  return {
    accept: adapter.accept,
    add(state: { file: File }): Added {
      const added = adapter.add(state);
      if (isGenerator(added)) return reportingGenerator(added, state.file.name, report);
      return added.catch((error: unknown) => {
        report(describeAttachmentError(state.file.name, error));
        throw error;
      });
    },
    async send(attachment: PendingAttachment): Promise<CompleteAttachment> {
      try {
        return await adapter.send(attachment);
      } catch (error) {
        report(describeAttachmentError(attachment.name, error));
        throw error;
      }
    },
    remove: (attachment) => adapter.remove(attachment),
  };
}
