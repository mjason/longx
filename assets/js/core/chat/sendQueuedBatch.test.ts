import { beforeEach, expect, test, vi } from "vitest";
import type { AppendMessage } from "@assistant-ui/react";
import { sendQueuedBatch } from "./sendQueuedBatch";
import { failed, ok } from "@/ui/test-mocks";

vi.mock("@/core/api", async () => (await import("@/ui/test-mocks")).rpcMock());
import { sendMessageBatch } from "@/core/api";

const messages: AppendMessage[] = ["first", "then this"].map(text => ({
  role: "user", parentId: null, sourceId: null, createdAt: new Date(),
  metadata: { custom: {} }, runConfig: undefined, content: [{ type: "text", text }],
  attachments: [],
}));
const options = () => ({
  target: { threadId: "t1", kernelThreadId: "thr_1" },
  model: "plus", effort: "high", after: 5,
  pending: { add: vi.fn().mockReturnValueOnce("e1").mockReturnValueOnce("e2"), update: vi.fn(), drop: vi.fn() },
});

beforeEach(() => vi.mocked(sendMessageBatch).mockReset().mockResolvedValue(ok({ id: "turn-row" }) as never));

test("one batch RPC retains distinct messages, model choice, and separate optimistic echoes", async () => {
  const opts = options();
  await sendQueuedBatch(messages, opts);
  expect(sendMessageBatch).toHaveBeenCalledExactlyOnceWith({ input: {
    threadId: "t1", model: "plus", effort: "high",
    messages: [{ text: "first", images: [] }, { text: "then this", images: [] }],
  } });
  expect(opts.pending.add).toHaveBeenNthCalledWith(1, { ...opts.target, text: "first", images: [], kind: "message", after: 5 });
  expect(opts.pending.add).toHaveBeenNthCalledWith(2, { ...opts.target, text: "then this", images: [], kind: "steer", after: 5 });
});

test("a failure marks every echo and rejects so the driver can restore the entire batch", async () => {
  const opts = options();
  vi.mocked(sendMessageBatch).mockResolvedValueOnce(failed("offline") as never);
  await expect(sendQueuedBatch(messages, opts)).rejects.toThrow("offline");
  expect(opts.pending.update).toHaveBeenCalledWith("e1", { error: expect.stringContaining("offline") });
  expect(opts.pending.update).toHaveBeenCalledWith("e2", { error: expect.stringContaining("offline") });
});
