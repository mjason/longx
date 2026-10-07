import { expect, test, vi } from "vitest";
import type { AttachmentAdapter, PendingAttachment } from "@assistant-ui/react";
import { trackAttachmentActivity } from "./attachmentActivity";

const pending = { id: "a", name: "a.pdf", type: "file", file: new File(["pdf"], "a.pdf"),
  status: { type: "requires-action", reason: "composer-send" } } satisfies PendingAttachment;

test("counts a promise upload before its first chip, then releases it on success or error", async () => {
  let finish!: (attachment: PendingAttachment) => void;
  const changed = vi.fn();
  const adapter = trackAttachmentActivity({
    accept: "*", add: () => new Promise(resolve => { finish = resolve; }),
    send: vi.fn(), remove: vi.fn(),
  } as AttachmentAdapter, changed);
  const task = adapter.add({ file: pending.file });
  expect(changed).toHaveBeenLastCalledWith(1);
  finish(pending);
  await task;
  expect(changed).toHaveBeenLastCalledWith(0);
  const failure = trackAttachmentActivity({
    accept: "*", add: () => Promise.reject(new Error("upload failed")),
    send: vi.fn(), remove: vi.fn(),
  } as AttachmentAdapter, changed);
  await expect(failure.add({ file: pending.file })).rejects.toThrow("upload failed");
  expect(changed).toHaveBeenLastCalledWith(0);
});

test("keeps a generator upload counted until it finishes", async () => {
  const changed = vi.fn();
  const adapter = trackAttachmentActivity({
    accept: "*", async *add() { yield pending; },
    send: vi.fn(), remove: vi.fn(),
  } as AttachmentAdapter, changed);
  const stream = adapter.add({ file: pending.file }) as AsyncGenerator<PendingAttachment, void>;
  expect(changed).toHaveBeenLastCalledWith(1);
  await stream.next();
  expect(changed).toHaveBeenLastCalledWith(1);
  await stream.next();
  expect(changed).toHaveBeenLastCalledWith(0);
});
