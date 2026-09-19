import { screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, test, vi } from "vitest";
import { renderAt, setViewport } from "@/ui/test-utils";
import { _resetFrameStoreForTests } from "@/core/frame";
import { channel, ok } from "@/ui/test-mocks";

vi.mock("@/ash_rpc", async () => (await import("@/ui/test-mocks")).rpcMock());
vi.mock("@/core/socket", async () => (await import("@/ui/test-mocks")).socketMock());
import { listSubagents } from "@/ash_rpc";

const subagents = [
  { id: "t9", kernelThreadId: "thr_1-alpha", title: "alpha", preview: "read a.txt", status: "active", agentPath: "/root/alpha", lastActivityAt: "2026-09-13T01:00:00Z", insertedAt: "2026-09-13T00:59:00Z" },
  { id: "t10", kernelThreadId: "thr_1-beta", title: "beta", preview: "read b.txt", status: "idle", agentPath: "/root/beta", lastActivityAt: "2026-09-13T01:00:30Z", insertedAt: "2026-09-13T00:59:00Z" },
  { id: "t11", kernelThreadId: "thr_1-gamma", title: "gamma", preview: null, status: "unrecoverable", agentPath: "/root/gamma", lastActivityAt: "2026-09-13T01:00:30Z", insertedAt: "2026-09-13T00:59:00Z" },
];

describe("AgentsTool", () => {
  beforeEach(() => {
    localStorage.clear();
    _resetFrameStoreForTests();
    channel.reset();
    setViewport(1280);
    vi.mocked(listSubagents).mockResolvedValue(ok(subagents) as never);
  });

  test("⌘4 lists the thread's sub-agents as background runs; a finished one opens as a workbench tab", async () => {
    const user = userEvent.setup();
    const { router } = renderAt("/p/app-1/t/t1");
    await waitFor(() => expect(channel.topics).toContain("thread:thr_1"));
    await user.keyboard("{Meta>}4{/Meta}");
    const panel = await screen.findByTestId("tool-panel");
    await within(panel).findByText("alpha");
    expect(listSubagents).toHaveBeenCalledWith(expect.objectContaining({ input: { parentThreadId: "t1" } }));
    expect(within(panel).getByText("read b.txt")).toBeInTheDocument();
    expect(within(panel).getByRole("button", { name: /alpha/ })).toBeDisabled();
    await user.click(within(panel).getByRole("button", { name: /beta/ }));
    // the conversation opens beside the chat, the page stays the parent's
    const pane = await screen.findByTestId("agent-tab");
    expect(pane).toHaveTextContent("beta");
    expect(screen.getByRole("link", { name: /到它的页面去对话/ })).toHaveAttribute("href", "/p/app-1/t/t10");
    expect(router.state.location.pathname).toBe("/p/app-1/t/t1");
  });

  test("a thread without sub-agents says so", async () => {
    vi.mocked(listSubagents).mockResolvedValue(ok([]) as never);
    const user = userEvent.setup();
    renderAt("/p/app-1/t/t1");
    await waitFor(() => expect(channel.topics).toContain("thread:thr_1"));
    await user.keyboard("{Meta>}4{/Meta}");
    const panel = await screen.findByTestId("tool-panel");
    await within(panel).findByText("这个会话没有派出子 agent");
  });
});
