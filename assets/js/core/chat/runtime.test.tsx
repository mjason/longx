import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { act, renderHook, waitFor } from "@testing-library/react";
import type { ReactNode } from "react";
import { beforeEach, describe, expect, test, vi } from "vitest";
import { channel, ok, thread } from "@/ui/test-mocks";
import { useCodexRuntime } from "./runtime";

vi.mock("@/ash_rpc", async () => (await import("@/ui/test-mocks")).rpcMock());
vi.mock("@/core/socket", async () => (await import("@/ui/test-mocks")).socketMock());
import { listThreads } from "@/ash_rpc";

const defaults = { sandbox: "workspace_write", approvalPolicy: "on_request", networkAccess: false, webSearch: true, multiAgent: true } as const;

const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
function wrapper({ children }: { children: ReactNode }) {
  return <QueryClientProvider client={client}>{children}</QueryClientProvider>;
}

describe("useCodexRuntime", () => {
  beforeEach(() => {
    channel.reset();
    vi.mocked(listThreads).mockResolvedValue(ok([thread(1)]) as never);
  });

  test("what the runtime is fed stays referentially stable across renders that change nothing", async () => {
    // assistant-ui's useExternalStoreRuntime calls setAdapter after every render; an adapter
    // (or its thread list / mode) rebuilt each time notifies the store on every commit —
    // a render loop once anything subscribed re-renders the provider
    const onOpenThread = () => {};
    const { result, rerender } = renderHook(() => useCodexRuntime({ projectId: "id-1", defaults, threadId: "t1", onOpenThread }), { wrapper });
    await waitFor(() => expect(result.current.thread).toBeDefined());
    await waitFor(() => expect(channel.topics).toContain("thread:thr_1"));
    act(() => channel.reply("ok", { thread_id: "thr_1", seq: 1, thread: null, turn: null, status: null, token_usage: null, items: [], pending_requests: [] }));
    const before = { mode: result.current.mode, view: result.current.view, subviews: result.current.subviews, runtime: result.current.runtime };
    rerender();
    rerender();
    expect(result.current.mode).toBe(before.mode);
    expect(result.current.view).toBe(before.view);
    expect(result.current.subviews).toBe(before.subviews);
    expect(result.current.runtime).toBe(before.runtime);
    // and the store was not told about a "new" thread list / messages on those renders
    const listSubscriber = vi.fn();
    const unsubscribe = result.current.runtime.threads.subscribe(listSubscriber);
    rerender();
    await act(async () => {});
    expect(listSubscriber).not.toHaveBeenCalled();
    unsubscribe();
  });
});
