// A text file dropped on the composer is inlined into the message (the
// model reads it as part of the prompt) — up to a point: a 251 KB text
// file is sixty to a hundred thousand tokens, most of a window, a fold on
// arrival. Past `INLINE_TEXT_LIMIT` it goes the way of a zip or a PDF: up to
// the server, its path in the message, the agent reading what it needs with
// sed and rg. The composite adapter picks by `accept` alone, so this one
// stands for the text types and decides by size which inner adapter takes
// the file; a send or a remove follows the add. DOM-free.
import type { AttachmentAdapter, CompleteAttachment, PendingAttachment } from "@assistant-ui/react";
import { isGenerator, type Added } from "./attachments";

/** the largest text file inlined into the prompt; bigger ones are uploaded */
export const INLINE_TEXT_LIMIT = 32 * 1024;

export class TextAttachmentAdapter implements AttachmentAdapter {
  accept: string;
  // the ids the upload took (the inline adapter took the rest)
  private uploaded = new Set<string>();

  constructor(
    private readonly inline: AttachmentAdapter,
    private readonly upload: AttachmentAdapter,
    private readonly limit = INLINE_TEXT_LIMIT,
  ) {
    this.accept = inline.accept;
  }

  add(state: { file: File }): Added {
    const big = state.file.size > this.limit;
    const added = (big ? this.upload : this.inline).add(state);
    if (!big) return added;
    if (isGenerator(added)) return this.tracking(added);
    return added.then((attachment) => {
      this.uploaded.add(attachment.id);
      return attachment;
    });
  }

  private async *tracking(added: AsyncGenerator<PendingAttachment, void>): AsyncGenerator<PendingAttachment, void> {
    for await (const step of added) {
      this.uploaded.add(step.id);
      yield step;
    }
  }

  send(attachment: PendingAttachment): Promise<CompleteAttachment> {
    return (this.uploaded.has(attachment.id) ? this.upload : this.inline).send(attachment);
  }

  async remove(attachment: { id: string }): Promise<void> {
    const target = this.uploaded.has(attachment.id) ? this.upload : this.inline;
    this.uploaded.delete(attachment.id);
    await target.remove(attachment as PendingAttachment);
  }
}
