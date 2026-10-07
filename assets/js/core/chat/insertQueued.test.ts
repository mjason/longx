import { beforeEach, expect, test, vi } from "vitest";
import type { AppendMessage } from "@assistant-ui/react";
import { createQueuedMessages } from "./queuedMessages";
import { insertQueuedMessage } from "./insertQueued";
import { inputOf } from "./adapter";
import { attachmentLine } from "./fileAttachments";
import { failed, ok } from "@/ui/test-mocks";

vi.mock("@/core/api", async () => (await import("@/ui/test-mocks")).rpcMock());
import { sendMessage, steerTurn } from "@/core/api";

const image = "data:image/png;base64,AAAA";
const original: AppendMessage = {
  role: "user", parentId: null, sourceId: null,
  createdAt: new Date(), metadata: { custom: {} }, runConfig: undefined,
  content: [{ type: "text", text: 'look @session("other:main")' }],
  attachments: [
    { id: "image", type: "image", name: "shot.png", contentType: "image/png", status: { type: "complete" }, content: [{ type: "image", image }] },
    { id: "inline", type: "document", name: "notes.txt", contentType: "text/plain", status: { type: "complete" }, content: [{ type: "text", text: "inline notes" }] },
    { id: "file", type: "file", name: "data.zip", contentType: "application/zip", status: { type: "complete" }, content: [{ type: "text", text: attachmentLine("data.zip", "/server/data.zip", 4) }] },
  ],
};

function setup(message = original) {
  const queue = createQueuedMessages({ run: vi.fn() });
  queue.notifyBusy();
  queue.adapter.steer(message);
  const id = queue.adapter.steerItems[0]!.id;
  const opts = {
    target: { threadId: "row-1", kernelThreadId: "thr_1" }, after: 2,
    model: "glm-5", effort: "high",
    pending: { add: vi.fn(() => "echo"), update: vi.fn(), drop: vi.fn() },
    invalidate: vi.fn(async () => {}),
  };
  return { queue, id, opts };
}

beforeEach(() => {
  vi.mocked(steerTurn).mockReset().mockResolvedValue(ok({ kernelTurnId: "turn_1" }) as never);
  vi.mocked(sendMessage).mockReset().mockResolvedValue(ok({ id: "turn-row" }) as never);
});

test("steer and echo carry the complete normalized message; only success removes it", async () => {
  const { queue, id, opts } = setup();
  await insertQueuedMessage(queue, id, opts);
  const payload = inputOf(original);
  expect(steerTurn).toHaveBeenCalledExactlyOnceWith({ input: { threadId: "row-1", ...payload } });
  expect(opts.pending.add).toHaveBeenCalledWith({ ...opts.target, ...payload, after: 2, kind: "steer" });
  expect(queue.getOriginal(id)).toBeUndefined();
  expect(opts.invalidate).toHaveBeenCalledOnce();
  expect(sendMessage).not.toHaveBeenCalled();
});

test("not_running fallback keeps images, file texts and chosen model; waits for success", async () => {
  const { queue, id, opts } = setup();
  vi.mocked(steerTurn).mockResolvedValueOnce(failed("not_running") as never);
  let finish!: (value: never) => void;
  vi.mocked(sendMessage).mockImplementationOnce(() => new Promise((resolve) => { finish = resolve; }));
  const sending = insertQueuedMessage(queue, id, opts);
  await vi.waitFor(() => expect(sendMessage).toHaveBeenCalledOnce());
  expect(sendMessage).toHaveBeenCalledWith({ input: {
    threadId: "row-1", ...inputOf(original), model: "glm-5", effort: "high",
  } });
  expect(queue.getOriginal(id)).toBe(original);
  expect(opts.pending.update).toHaveBeenCalledWith("echo", { kind: "message" });
  finish(ok({ id: "turn-row" }) as never);
  await sending;
  expect(queue.getOriginal(id)).toBeUndefined();
});

test.each(["steer", "fallback", "network"] as const)("%s failure retains original for retry and reports the error", async (mode) => {
  const { queue, id, opts } = setup();
  if (mode === "fallback") {
    vi.mocked(steerTurn).mockResolvedValueOnce(failed("not_running") as never);
    vi.mocked(sendMessage).mockResolvedValueOnce(failed("unavailable") as never);
  } else if (mode === "network") {
    vi.mocked(steerTurn).mockRejectedValueOnce(new Error("unavailable"));
  } else {
    vi.mocked(steerTurn).mockResolvedValueOnce(failed("unavailable") as never);
  }
  await expect(insertQueuedMessage(queue, id, opts)).resolves.toBeUndefined();
  expect(queue.getOriginal(id)).toBe(original);
  expect(opts.pending.update).toHaveBeenCalledWith("echo", { error: "unavailable" });
  expect(opts.invalidate).not.toHaveBeenCalled();
  await insertQueuedMessage(queue, id, opts);
  expect(queue.getOriginal(id)).toBeUndefined();
  expect(steerTurn).toHaveBeenLastCalledWith({ input: { threadId: "row-1", ...inputOf(original) } });
});

test("repeated clicks while inserting cannot send the same item twice", async () => {
  const { queue, id, opts } = setup();
  let finish!: (value: never) => void;
  vi.mocked(steerTurn).mockImplementationOnce(() => new Promise((resolve) => { finish = resolve; }));
  const first = insertQueuedMessage(queue, id, opts);
  await insertQueuedMessage(queue, id, opts);
  expect(steerTurn).toHaveBeenCalledOnce();
  expect(opts.pending.add).toHaveBeenCalledOnce();
  finish(ok({ kernelTurnId: "turn_1" }) as never);
  await first;
});

test("pure image and pure uploaded file are not turned into an empty message", async () => {
  for (const attachment of [original.attachments![0]!, original.attachments![2]!]) {
    const message: AppendMessage = { ...original, content: [], attachments: [attachment] };
    const { queue, id, opts } = setup(message);
    await insertQueuedMessage(queue, id, opts);
    const { text, images } = inputOf(message);
    expect(steerTurn).toHaveBeenLastCalledWith({ input: { threadId: "row-1", text, ...(images.length ? { images } : {}) } });
    expect(queue.getOriginal(id)).toBeUndefined();
  }
});
