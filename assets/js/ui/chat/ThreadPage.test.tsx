import { act, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, test, vi } from "vitest";
import { renderAt, setViewport } from "@/ui/test-utils";
import { _resetFrameStoreForTests } from "@/core/frame";
import { channel } from "@/ui/test-mocks";

vi.mock("@/ash_rpc", async () => (await import("@/ui/test-mocks")).rpcMock());
vi.mock("@/core/socket", async () => (await import("@/ui/test-mocks")).socketMock());
import { respond, sendMessage } from "@/ash_rpc";

const snapshot = {
  thread_id: "thr_1",
  seq: 3,
  thread: { id: "thr_1" },
  turn: { id: "turn_1", status: "completed" },
  status: null,
  token_usage: null,
  items: [
    { id: "u1", type: "userMessage", turnId: "turn_1", content: [{ type: "text", text: "run the tests" }] },
    { id: "c1", type: "commandExecution", turnId: "turn_1", command: "mix test", cwd: "/p", status: "completed", exitCode: 0, aggregatedOutput: "12 tests, 0 failures\n" },
    { id: "a1", type: "agentMessage", turnId: "turn_1", text: "All **green**." },
  ],
  pending_requests: [],
};

async function open(path = "/p/app-1/t/t1") {
  const r = renderAt(path);
  await waitFor(() => expect(channel.topics).toContain("thread:thr_1"));
  act(() => channel.reply("ok", snapshot));
  await screen.findByText("run the tests");
  return r;
}

describe("ThreadPage", () => {
  beforeEach(() => {
    localStorage.clear();
    _resetFrameStoreForTests();
    channel.reset();
    vi.mocked(sendMessage).mockClear();
    vi.mocked(respond).mockClear();
    setViewport(1280);
  });

  test("renders the snapshot: user message, command block, markdown reply", async () => {
    await open();
    expect(screen.getByTestId("tool-command")).toHaveTextContent("mix test");
    expect(screen.getByText("12 tests, 0 failures")).toBeInTheDocument();
    expect(screen.getByText("green").tagName).toBe("STRONG");
  });

  test("the composer sends a turn with the picked model", async () => {
    const user = userEvent.setup();
    await open();
    await user.click(screen.getByTestId("model-picker"));
    await user.click(await screen.findByRole("option", { name: /glm-5/ }));
    await user.type(screen.getByRole("textbox", { name: /消息/ }), "next step{Enter}");
    await waitFor(() =>
      expect(sendMessage).toHaveBeenCalledWith(expect.objectContaining({ input: { threadId: "t1", text: "next step", model: "glm-5" } })),
    );
  });

  test("live events stream in; an approval can be answered from the message", async () => {
    const user = userEvent.setup();
    await open();
    act(() => {
      channel.push("codex", { seq: 4, method: "turn/started", params: { turn: { id: "turn_2", status: "inProgress" } } });
      channel.push("codex", { seq: 5, method: "item/started", params: { turnId: "turn_2", item: { id: "c2", type: "commandExecution", command: "rm -rf build", cwd: "/p", status: "inProgress" } } });
      channel.push("codex", { seq: 6, method: "item/commandExecution/requestApproval", params: { requestId: 7, itemId: "c2", threadId: "thr_1", turnId: "turn_2", command: "rm -rf build" } });
    });
    expect(screen.getByTestId("turn-bar")).toHaveTextContent("等待审批");
    await user.click(screen.getByRole("button", { name: "允许" }));
    await waitFor(() => expect(respond).toHaveBeenCalledWith(expect.objectContaining({ input: { threadId: "t1", requestId: "7", decision: "accept" } })));
    // the composer offers stop while the turn runs
    expect(screen.getByRole("button", { name: /停止/ })).toBeInTheDocument();
  });

  test("an unrecoverable thread cannot take messages", async () => {
    const { listThreads } = await import("@/ash_rpc");
    vi.mocked(listThreads).mockResolvedValueOnce({
      success: true,
      data: [{ id: "t1", codexThreadId: "thr_1", title: null, preview: "x", status: "unrecoverable", modelSlug: null, lastActivityAt: null, insertedAt: "2026-09-12T00:00:00Z" }],
    } as never);
    await open();
    expect(screen.getByRole("alert")).toHaveTextContent("codex 已不认识这个会话");
    expect(screen.getByRole("textbox", { name: /消息/ })).toBeDisabled();
  });

  test("phone: the chat still shows the command block and the bottom toolbar", async () => {
    setViewport(390);
    await open();
    expect(screen.getByTestId("bottom-toolbar")).toBeInTheDocument();
    expect(within(screen.getByTestId("chat-area")).getByTestId("tool-command")).toBeInTheDocument();
  });
});
