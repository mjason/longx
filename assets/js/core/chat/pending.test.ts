import { describe, expect, test } from "vitest";
import { forThread, pendingMessages, settled, type PendingSend } from "./pending";
import { emptyView, type ThreadView } from "./thread";

const send = (over: Partial<PendingSend>): PendingSend => ({
  id: "p1",
  threadId: "t1",
  kernelThreadId: "thr_1",
  text: "hi",
  images: [],
  kind: "message",
  after: 0,
  at: 1,
  ...over,
});

const view = (items: ThreadView["items"], threadId = "thr_1"): ThreadView => ({ ...emptyView(threadId), items });
const user = (id: string, text: string, extra: Record<string, unknown> = {}) => ({ id, type: "userMessage", turnId: "turn_2", content: [{ type: "text", text }], ...extra });

describe("a message's echo while it travels", () => {
  test("a pending send is a user message with its text and images, marked pending by kind, its error when it failed", () => {
    const msgs = pendingMessages([send({ images: ["data:image/png;base64,x"] }), send({ id: "p2", kind: "steer", text: "and this", error: "boom" })]);
    expect(msgs[0]).toEqual({
      id: "pending:p1",
      role: "user",
      content: [
        { type: "text", text: "hi" },
        { type: "image", image: "data:image/png;base64,x" },
      ],
      metadata: { custom: { pending: "message" } },
    });
    expect(msgs[1]).toMatchObject({ id: "pending:p2", metadata: { custom: { pending: "steer", error: "boom" } } });
  });

  test("the echo goes once the view shows the person's message after the items it was sent over — each item settles one echo, the same words twice need two", () => {
    const pending = [send({ id: "a", text: "继续", after: 1 }), send({ id: "b", text: "继续", after: 1 })];
    // an older 继续 sits before `after`: not this one
    const older = view([user("u0", "继续")]);
    expect(settled(pending, older)).toBe(pending);
    const one = view([user("u0", "继续"), user("u1", "继续")]);
    expect(settled(pending, one).map((p) => p.id)).toEqual(["b"]);
    const two = view([user("u0", "继续"), user("u1", "继续"), user("u2", "继续")]);
    expect(settled(pending, two)).toEqual([]);
  });

  test("another agent's words, a job's notice and another thread's items settle nothing; a failed send stays until dropped", () => {
    const pending = [send({ text: "hi" }), send({ id: "p2", text: "x", error: "no" })];
    const agent = view([user("u1", "[agent coder] hi", { from: "coder" }), user("u2", "hi", { origin: { kind: "job", name: "x" } })]);
    expect(settled(pending, agent)).toBe(pending);
    const other = view([user("u1", "hi")], "thr_9");
    expect(settled(pending, other)).toBe(pending);
    const here = view([user("u1", "hi"), user("u2", "x")]);
    expect(settled(pending, here).map((p) => p.id)).toEqual(["p2"]);
  });

  test("the page shows the echoes of its thread, and of a thread still being made (the first message of a new chat)", () => {
    const pending = [send({ id: "a", threadId: "t1" }), send({ id: "b", threadId: null, kernelThreadId: null }), send({ id: "c", threadId: "t2" })];
    expect(forThread(pending, "t1").map((p) => p.id)).toEqual(["a", "b"]);
    expect(forThread(pending, undefined).map((p) => p.id)).toEqual(["b"]);
    const mine = [send({ id: "a", threadId: "t1" })];
    expect(forThread(mine, "t1")).toBe(mine);
  });
});
