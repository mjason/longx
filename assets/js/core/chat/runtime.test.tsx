import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { act, renderHook, waitFor } from "@testing-library/react";
import type { ReactNode } from "react";
import { beforeEach, describe, expect, test, vi } from "vitest";
import { channel, ok, thread } from "@/ui/test-mocks";
import { useCodexRuntime } from "./runtime";

vi.mock("@/ash_rpc", async () => (await import("@/ui/test-mocks")).rpcMock());
vi.mock("@/core/socket", async () => (await import("@/ui/test-mocks")).socketMock());
import { archiveThread, deleteThread, getThread, listThreads, startThread } from "@/ash_rpc";

const defaults = { sandbox: "workspace_write", approvalPolicy: "on_request", networkAccess: false, webSearch: true, multiAgent: true, autoReview: true } as const;

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

  test("deleting or archiving the thread on screen leaves it for a new chat; another thread does not move the page", async () => {
    vi.mocked(listThreads).mockResolvedValue(ok([thread(1), thread(2)]) as never);
    const onOpenThread = vi.fn();
    const { result } = renderHook(() => useCodexRuntime({ projectId: "id-1", defaults, threadId: "t1", onOpenThread }), { wrapper });
    await waitFor(() => expect(result.current.thread).toBeDefined());
    const list = result.current.runtime.threads;
    await waitFor(() => expect(list.getState().threadIds.length + list.getState().archivedThreadIds.length).toBe(2));

    await act(async () => { await list.getItemById("t2").delete(); });
    expect(deleteThread).toHaveBeenCalledWith(expect.objectContaining({ input: { threadId: "t2" } }));
    expect(onOpenThread).not.toHaveBeenCalled();

    await act(async () => { await list.getItemById("t1").archive(); });
    expect(archiveThread).toHaveBeenCalledWith(expect.objectContaining({ identity: "t1" }));
    expect(onOpenThread).toHaveBeenCalledWith(null);

    onOpenThread.mockClear();
    await act(async () => { await list.getItemById("t1").delete(); });
    expect(onOpenThread).toHaveBeenCalledWith(null);
  });

  test("新会话 opens the new-chat page — no row, no codex thread until the first message", async () => {
    vi.mocked(listThreads).mockResolvedValue(ok([thread(1)]) as never);
    const onOpenThread = vi.fn();
    const { result } = renderHook(() => useCodexRuntime({ projectId: "id-1", defaults, threadId: "t1", onOpenThread }), { wrapper });
    await waitFor(() => expect(result.current.thread).toBeDefined());

    await act(async () => { await result.current.runtime.threads.switchToNewThread(); });
    expect(onOpenThread).toHaveBeenCalledWith(null);
    expect(startThread).not.toHaveBeenCalled();
  });

  test("a sub-agent's page: a thread the project's list hides (it has a parent) is fetched by id, not 找不到", async () => {
    vi.mocked(listThreads).mockResolvedValue(ok([thread(1)]) as never);
    vi.mocked(getThread).mockResolvedValue(ok({ ...thread(9), parentThreadId: "t1", agentPath: "/root/researcher", title: "researcher" }) as never);
    const { result } = renderHook(() => useCodexRuntime({ projectId: "id-1", defaults, threadId: "t9", onOpenThread: () => {} }), { wrapper });
    await waitFor(() => expect(result.current.thread?.id).toBe("t9"));
    expect(result.current.missing).toBe(false);
    expect(getThread).toHaveBeenCalledWith(expect.objectContaining({ input: { id: "t9" } }));
  });

  test("the first message of a new chat opens its thread without a moment of 找不到这个会话: the row is in the list before the page moves", async () => {
    // the refetch after start_thread is still in flight when the router
    // already shows the new id
    vi.mocked(listThreads).mockResolvedValue(ok([thread(1)]) as never);
    let threadId: string | undefined = undefined;
    const onOpenThread = vi.fn((id: string | null) => { threadId = id ?? undefined; });
    const { result, rerender } = renderHook(() => useCodexRuntime({ projectId: "id-1", defaults, threadId, onOpenThread }), { wrapper });
    await waitFor(() => expect(result.current.runtime).toBeDefined());
    let land: (rows: unknown) => void = () => {};
    vi.mocked(listThreads).mockImplementation(() => new Promise((resolve) => { land = resolve; }) as never);

    await act(async () => { await result.current.runtime.thread.append({ role: "user", content: [{ type: "text", text: "hi" }] }); });
    expect(startThread).toHaveBeenCalled();
    expect(onOpenThread).toHaveBeenCalledWith("t2");
    rerender();
    expect(result.current.missing).toBe(false);
    expect(result.current.thread?.id).toBe("t2");
    await act(async () => { land(ok([thread(2), thread(1)])); });
    expect(result.current.thread?.id).toBe("t2");
  });
});
