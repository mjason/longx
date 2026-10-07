import { afterEach, beforeEach, expect, test, vi } from "vitest";
import type { LongxRuntime } from "./runtime";
import { ChatSessionPool, sessionKey, type SessionOptions } from "./sessionPool";

const options = (threadId: string | undefined = "t1"): SessionOptions => ({
  projectId: "p1", threadId, onOpenThread: vi.fn(), onBackgroundThread: vi.fn(),
});
function fakeChat(state: { attachments?: unknown[]; queue?: unknown[]; text?: string } = {}, echoes: unknown[] = []): LongxRuntime {
  return { runtime: { thread: { composer: { getState: () => ({
    attachments: state.attachments ?? [], queue: state.queue ?? [], text: state.text ?? "",
  }) } } }, echoes } as unknown as LongxRuntime;
}

beforeEach(() => vi.useFakeTimers());
afterEach(() => vi.useRealTimers());

test("an inactive attachment session retains the same runtime and adapter owner", () => {
  const pool = new ChatSessionPool();
  const opts = options();
  const entry = pool.acquire(opts);
  const chat = fakeChat({ attachments: [{}] });
  pool.publish(entry, chat);
  pool.release(entry);
  vi.runAllTimers();
  expect(pool.getChat(sessionKey("p1", "t1"))).toBe(chat);
  expect(pool.acquire(opts)).toBe(entry);
  pool.clear();
});

test("empty inactive sessions leave, but a quick reacquire cancels disposal", () => {
  const pool = new ChatSessionPool();
  const entry = pool.acquire(options());
  pool.publish(entry, fakeChat());
  pool.release(entry);
  expect(pool.acquire(options())).toBe(entry);
  vi.runAllTimers();
  expect(pool.getSessions()).toHaveLength(1);
  pool.release(entry);
  vi.runAllTimers();
  expect(pool.getSessions()).toHaveLength(0);
});

test("a pending upload is retained before it has produced any attachment chip", () => {
  const pool = new ChatSessionPool();
  const entry = pool.acquire(options());
  pool.publish(entry, fakeChat());
  pool.attachmentActivity(entry, 1);
  pool.release(entry);
  vi.runAllTimers();
  expect(pool.getSessions()).toHaveLength(1);
  pool.attachmentActivity(entry, 0);
  // Upload continuation publishes the new chip before deferred disposal.
  pool.publish(entry, fakeChat({ attachments: [{}] }));
  vi.runAllTimers();
  expect(pool.getSessions()).toHaveLength(1);
  pool.clear();
});

test("queued messages and pending sends retain their background sessions until settled", () => {
  const pool = new ChatSessionPool();
  const entry = pool.acquire(options());
  pool.publish(entry, fakeChat({ queue: [{}] }));
  pool.release(entry);
  vi.runAllTimers();
  expect(pool.getSessions()).toHaveLength(1);
  pool.publish(entry, fakeChat({}, [{ error: undefined }]));
  vi.runAllTimers();
  expect(pool.getSessions()).toHaveLength(1);
  pool.publish(entry, fakeChat());
  vi.runAllTimers();
  expect(pool.getSessions()).toHaveLength(0);
});

test("a background new-chat send adopts its row without navigating the visible project", () => {
  const pool = new ChatSessionPool();
  const opts = { ...options(), threadId: undefined };
  const entry = pool.acquire(opts);
  pool.publish(entry, fakeChat({ attachments: [{}] }));
  pool.release(entry);
  pool.openThread(entry, "created-row");
  expect(opts.onOpenThread).not.toHaveBeenCalled();
  expect(opts.onBackgroundThread).toHaveBeenCalledWith("created-row");
  expect(pool.acquire({ ...opts, threadId: "created-row" })).toBe(entry);
  expect(pool.getSessions()).toHaveLength(1);
  pool.clear();
});
