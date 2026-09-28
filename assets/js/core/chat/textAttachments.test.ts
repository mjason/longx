import { describe, expect, test, vi } from "vitest";
import type { AttachmentAdapter, CompleteAttachment, PendingAttachment } from "@assistant-ui/react";
import { INLINE_TEXT_LIMIT, TextAttachmentAdapter } from "./textAttachments";

const fake = (label: string, accept = "*"): AttachmentAdapter & { add: ReturnType<typeof vi.fn>; send: ReturnType<typeof vi.fn>; remove: ReturnType<typeof vi.fn> } => ({
  accept,
  add: vi.fn(async ({ file }: { file: File }): Promise<PendingAttachment> => ({
    id: `${label}-${file.name}`,
    type: "document",
    name: file.name,
    contentType: file.type,
    file,
    status: { type: "requires-action", reason: "composer-send" },
  })),
  send: vi.fn(async (a: PendingAttachment): Promise<CompleteAttachment> => ({ ...a, status: { type: "complete" }, content: [{ type: "text", text: label }] })),
  remove: vi.fn(async () => {}),
});

const text = (name: string, bytes: number) => new File([new Uint8Array(bytes)], name, { type: "text/plain" });
// the adapters here answer with the attachment, never a progress stream
const added = async (adapter: AttachmentAdapter, file: File) => (await adapter.add({ file })) as PendingAttachment;

describe("TextAttachmentAdapter", () => {
  test("a text file within the limit is inlined; one past it is uploaded like any other file, and its send and remove go the same way", async () => {
    const inline = fake("inline", "text/plain,text/markdown");
    const upload = fake("upload");
    const adapter = new TextAttachmentAdapter(inline, upload);
    // the same files the inline adapter takes
    expect(adapter.accept).toContain("text/plain");
    expect(adapter.accept).toContain("text/markdown");
    expect(INLINE_TEXT_LIMIT).toBe(32 * 1024);

    const small = await added(adapter, text("notes.txt", INLINE_TEXT_LIMIT));
    expect(small.id).toBe("inline-notes.txt");
    expect(upload.add).not.toHaveBeenCalled();
    expect((await adapter.send(small)).content).toEqual([{ type: "text", text: "inline" }]);

    const big = await added(adapter, text("dump.txt", INLINE_TEXT_LIMIT + 1));
    expect(big.id).toBe("upload-dump.txt");
    expect(inline.add).toHaveBeenCalledTimes(1);
    expect((await adapter.send(big)).content).toEqual([{ type: "text", text: "upload" }]);

    await adapter.remove(big);
    expect(upload.remove).toHaveBeenCalledWith(big);
    expect(inline.remove).not.toHaveBeenCalled();
    await adapter.remove(small);
    expect(inline.remove).toHaveBeenCalledWith(small);
    // the routing is forgotten with the attachment
    expect(upload.remove).toHaveBeenCalledTimes(1);
  });
});
