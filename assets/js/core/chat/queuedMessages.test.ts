import { expect, test, vi } from "vitest";
import type { AppendMessage } from "@assistant-ui/react";
import { createQueuedMessages } from "./queuedMessages";

const message = (text: string): AppendMessage => ({
  role: "user", content: [{ type: "text", text }], parentId: null, sourceId: null,
  createdAt: new Date(), metadata: { custom: {} }, runConfig: undefined,
  attachments: [{
    id: "file", type: "file", name: "data.zip", contentType: "application/zip",
    status: { type: "complete" }, content: [{ type: "text", text: "/server/data.zip" }],
  }],
});

test("originals keep attachment text that QueueItem.parts omits, in both lanes", () => {
  const queue = createQueuedMessages({ run: vi.fn() });
  queue.notifyBusy();
  const first = message("first");
  const second = message("second");
  const observed: AppendMessage[] = [];
  queue.subscribe(() => {
    for (const item of [...queue.adapter.items, ...queue.adapter.steerItems]) {
      observed.push(queue.getOriginal(item.id)!);
    }
  });
  queue.adapter.enqueue(first);
  queue.adapter.steer(second);
  expect(queue.adapter.items[0]!.parts).toEqual(first.content);
  expect(queue.getOriginal(queue.adapter.items[0]!.id)).toBe(first);
  expect(queue.getOriginal(queue.adapter.steerItems[0]!.id)).toBe(second);
  expect(observed).not.toContain(undefined);
});

test("edit and lane moves retain full content; remove, natural drain and clear release it", () => {
  const run = vi.fn();
  const queue = createQueuedMessages({ run });
  queue.notifyBusy();
  queue.adapter.enqueue(message("first"));
  queue.adapter.enqueue(message("second"));
  const [first, second] = queue.adapter.items;
  const edited = message("edited");
  queue.adapter.edit!(first!.id, edited);
  queue.adapter.move!(first!.id, { lane: "steer" });
  expect(queue.getOriginal(first!.id)).toBe(edited);
  queue.notifyIdle();
  expect(run).toHaveBeenLastCalledWith(edited, { steer: false });
  expect(queue.getOriginal(first!.id)).toBeUndefined();
  queue.adapter.remove(second!.id);
  expect(queue.getOriginal(second!.id)).toBeUndefined();
  queue.adapter.enqueue(message("clear"));
  const id = queue.adapter.items[0]!.id;
  queue.clear();
  expect(queue.getOriginal(id)).toBeUndefined();
  expect(queue.adapter.items).toHaveLength(0);
  expect(() => queue.adapter.edit!("unknown", edited)).toThrow(/Unknown queue item/);
});

test("idle enqueue dispatches the original once without retaining it", () => {
  const run = vi.fn();
  const queue = createQueuedMessages({ run });
  const original = message("send now");
  queue.adapter.enqueue(original);
  expect(run).toHaveBeenCalledExactlyOnceWith(original, { steer: false });
  expect(queue.adapter.items).toHaveLength(0);
});

test("cancellation pauses draining without losing originals or attachments", () => {
  const run = vi.fn();
  const queue = createQueuedMessages({ run });
  queue.notifyBusy();
  const original = message("later");
  queue.adapter.steer(original);
  const id = queue.adapter.steerItems[0]!.id;
  queue.notifyCancelled();
  queue.notifyIdle();
  expect(run).not.toHaveBeenCalled();
  expect(queue.getOriginal(id)).toBe(original);
});

test("a finished run dispatches all queued originals once as a batch, preserving boundaries and attachments", async () => {
  const run = vi.fn();
  const runBatch = vi.fn(async () => {});
  const queue = createQueuedMessages({ run, runBatch });
  queue.notifyBusy();
  const first = message("first");
  const second = message("second");
  queue.adapter.enqueue(first);
  queue.adapter.enqueue(second);
  queue.notifyIdle();
  await Promise.resolve();
  expect(run).not.toHaveBeenCalled();
  expect(runBatch).toHaveBeenCalledExactlyOnceWith([first, second]);
  expect(queue.adapter.items).toHaveLength(0);
});

test("a failed batch restores every original in order and stays paused instead of retrying in a loop", async () => {
  const runBatch = vi.fn(async () => { throw new Error("offline"); });
  const queue = createQueuedMessages({ run: vi.fn(), runBatch });
  queue.notifyBusy();
  const messages = [message("first"), message("second")];
  messages.forEach(queue.adapter.enqueue);
  queue.notifyIdle();
  await Promise.resolve();
  await Promise.resolve();
  expect(queue.adapter.items.map(item => queue.getOriginal(item.id))).toEqual(messages);
  queue.notifyIdle();
  expect(runBatch).toHaveBeenCalledTimes(1);
});

test("batched dispatch applies the runtime's current metadata to every message", async () => {
  const runBatch = vi.fn(async (_messages: AppendMessage[]) => {});
  const queue = createQueuedMessages({ run: vi.fn(), runBatch });
  queue.notifyBusy();
  queue.adapter.enqueue(message("first"));
  queue.adapter.enqueue(message("second"));
  queue.adapter.__internal_setDispatchTransform!(original => ({ ...original, parentId: "latest-tail" }));
  queue.notifyIdle();
  await Promise.resolve();
  expect(runBatch.mock.calls[0]![0].map((original: AppendMessage) => original.parentId)).toEqual(["latest-tail", "latest-tail"]);
});

test("a stop retains an entire batch, and inputs arriving during a failed dispatch follow the restored batch", async () => {
  let fail!: (error: Error) => void;
  const runBatch = vi.fn(() => new Promise<void>((_, reject) => { fail = reject; }));
  const queue = createQueuedMessages({ run: vi.fn(), runBatch });
  queue.notifyBusy();
  queue.adapter.enqueue(message("first"));
  queue.adapter.enqueue(message("second"));
  queue.notifyCancelled();
  queue.notifyIdle();
  expect(runBatch).not.toHaveBeenCalled();
  // An explicit new run re-arms draining after the stop.
  queue.notifyBusy();
  queue.notifyIdle();
  queue.adapter.enqueue(message("third"));
  fail(new Error("offline"));
  await Promise.resolve();
  await Promise.resolve();
  expect(queue.adapter.items.map(item => queue.getOriginal(item.id)!.content)).toEqual([
    [{ type: "text", text: "first" }], [{ type: "text", text: "second" }], [{ type: "text", text: "third" }],
  ]);
  expect(runBatch).toHaveBeenCalledTimes(1);
});
