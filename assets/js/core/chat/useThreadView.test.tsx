import { act, renderHook, waitFor } from "@testing-library/react";
import { beforeEach, expect, test, vi } from "vitest";
import { channel } from "@/ui/test-mocks";
import { clearThreadViewCache, getCachedThreadView } from "./threadViewCache";
import { useThreadView } from "./useThreadView";

vi.mock("@/core/socket", async () => (await import("@/ui/test-mocks")).socketMock());

beforeEach(() => {
  channel.reset();
  clearThreadViewCache();
});

test("leaving during a join never caches an empty view as a successfully loaded history", async () => {
  const first = renderHook(() => useThreadView("archived"));
  expect(first.result.current.ready).toBe(false);
  expect(getCachedThreadView("archived")).toBeUndefined();
  first.unmount();

  const second = renderHook(() => useThreadView("archived"));
  expect(second.result.current.ready).toBe(false);
  act(() => channel.replyTo("thread:archived", "ok", {
    seq: 0, thread_id: "archived", thread: { id: "archived", status: "archived" },
    turn: null, status: null, token_usage: null, pending_requests: [],
    items: [{ id: "report", type: "agentMessage", text: "History retained." }],
  }));
  await waitFor(() => expect(second.result.current.ready).toBe(true));
  expect(getCachedThreadView("archived")?.items[0]?.["text"]).toBe("History retained.");
  second.unmount();

  const third = renderHook(() => useThreadView("archived"));
  expect(third.result.current.ready).toBe(true);
  expect(third.result.current.view.items[0]?.["text"]).toBe("History retained.");
});
