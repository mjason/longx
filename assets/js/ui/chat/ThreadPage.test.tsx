import { act, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, test, vi } from "vitest";
import { renderAt, setViewport } from "@/ui/test-utils";
import { _resetFrameStoreForTests } from "@/core/frame";
import { channel, ok, thread } from "@/ui/test-mocks";

vi.mock("@/ash_rpc", async () => (await import("@/ui/test-mocks")).rpcMock());
vi.mock("@/core/socket", async () => (await import("@/ui/test-mocks")).socketMock());
import { answerRequest, listThreads, respond, sendMessage, startThread } from "@/ash_rpc";

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
    vi.mocked(listThreads).mockResolvedValue(ok([thread(1)]) as never);
    setViewport(1280);
  });

  test("renders the snapshot: user message, command block, markdown reply", async () => {
    await open();
    expect(screen.getByTestId("tool-command")).toHaveTextContent("mix test");
    // finished commands are collapsed rows; the output is a click away
    await userEvent.click(screen.getByRole("button", { name: /运行了/ }));
    expect(screen.getByText("12 tests, 0 failures")).toBeInTheDocument();
    expect(screen.getByText("green").tagName).toBe("STRONG");
  });

  test("the composer sends a turn with the picked model", async () => {
    const user = userEvent.setup();
    await open();
    await user.click(screen.getByTestId("model-picker"));
    await user.click(await screen.findByRole("option", { name: /glm-5/ }));
    await user.type(screen.getByRole("textbox", { name: "随心输入" }), "next step{Enter}");
    await waitFor(() =>
      expect(sendMessage).toHaveBeenCalledWith(expect.objectContaining({ input: { threadId: "t1", text: "next step", model: "glm-5" } })),
    );
  });

  test("live events stream in; an approval can be answered from the message", async () => {
    const user = userEvent.setup();
    await open();
    act(() => {
      channel.deliver("codex", { seq: 4, method: "turn/started", params: { turn: { id: "turn_2", status: "inProgress" } } });
      channel.deliver("codex", { seq: 5, method: "item/started", params: { turnId: "turn_2", item: { id: "c2", type: "commandExecution", command: "rm -rf build", cwd: "/p", status: "inProgress" } } });
      channel.deliver("codex", { seq: 6, method: "item/commandExecution/requestApproval", params: { requestId: 7, itemId: "c2", threadId: "thr_1", turnId: "turn_2", command: "rm -rf build" } });
    });
    expect(screen.getByTestId("turn-bar")).toHaveTextContent("等待审批");
    await user.click(screen.getByRole("button", { name: "允许" }));
    await waitFor(() => expect(respond).toHaveBeenCalledWith(expect.objectContaining({ input: { threadId: "t1", requestId: "7", decision: "accept" } })));
    // the composer offers stop while the turn runs
    expect(screen.getByRole("button", { name: /停止/ })).toBeInTheDocument();
  });

  test("an unrecoverable thread cannot take messages", async () => {
    vi.mocked(listThreads).mockResolvedValueOnce({
      success: true,
      data: [{ id: "t1", codexThreadId: "thr_1", title: null, preview: "x", status: "unrecoverable", modelSlug: null, lastActivityAt: null, insertedAt: "2026-09-12T00:00:00Z" }],
    } as never);
    await open();
    expect(screen.getByRole("alert")).toHaveTextContent("codex 已不认识这个会话");
    expect(screen.getByRole("textbox", { name: "随心输入" })).toBeDisabled();
  });

  test("the project route is a new chat: the first message creates the thread and opens it", async () => {
    const user = userEvent.setup();
    const { router } = renderAt("/p/app-1");
    await screen.findByText("让 agent 在这个项目里干活");
    expect(channel.topics.filter((t) => t.startsWith("thread:"))).toEqual([]);
    await user.type(screen.getByRole("textbox", { name: "随心输入" }), "start here{Enter}");
    await waitFor(() => expect(startThread).toHaveBeenCalled());
    await waitFor(() => expect(sendMessage).toHaveBeenCalledWith(expect.objectContaining({ input: { threadId: "t2", text: "start here" } })));
    await waitFor(() => expect(router.state.location.pathname).toBe("/p/app-1/t/t2"));
  });

  test("a disconnected thread keeps the input usable but cannot send", async () => {
    vi.mocked(listThreads).mockResolvedValue({
      success: true,
      data: [{ id: "t1", codexThreadId: "thr_1", title: null, preview: "x", status: "disconnected", modelSlug: null, lastActivityAt: null, insertedAt: "2026-09-12T00:00:00Z" }],
    } as never);
    await open();
    expect(screen.getByRole("alert")).toHaveTextContent("codex 断开了");
    const box = screen.getByRole("textbox", { name: "随心输入" });
    expect(box).toBeEnabled();
    expect(screen.getByRole("button", { name: "发送" })).toBeDisabled();
  });

  test("a question from codex is a form; the answers go back through answer_request", async () => {
    const user = userEvent.setup();
    await open();
    act(() => {
      channel.deliver("codex", { seq: 4, method: "turn/started", params: { turn: { id: "turn_2", status: "inProgress" } } });
      channel.deliver("codex", {
        seq: 5,
        method: "item/tool/requestUserInput",
        params: { requestId: 9, itemId: "call_9", threadId: "thr_1", turnId: "turn_2", isBlocking: true, questions: [{ id: "q1", header: "DB", question: "which db?", options: [{ label: "sqlite", description: "" }] }] },
      });
    });
    await user.click(screen.getByRole("button", { name: "sqlite" }));
    await user.click(screen.getByRole("button", { name: "发送" }));
    await waitFor(() => expect(answerRequest).toHaveBeenCalledWith(expect.objectContaining({ input: { threadId: "t1", requestId: "9", answers: { q1: { answers: ["sqlite"] } } } })));
  });

  test("a finished turn shows its timing; a revert re-pulls the snapshot", async () => {
    await open();
    // the snapshot's turn carries codex's epoch-second stamps
    expect(screen.queryByRole("button", { name: "这一轮的耗时" })).not.toBeInTheDocument();
    act(() => channel.reply("ok", { ...snapshot, seq: 4, turn: { id: "turn_1", status: "completed", startedAt: 1_700_000_000, completedAt: 1_700_000_007 } }));
    expect(await screen.findByRole("button", { name: "这一轮的耗时" })).toHaveTextContent("7");

    act(() => channel.deliver("codex", { seq: 5, method: "thread/reverted", params: { threadId: "thr_1", turnIds: ["turn_1"] } }));
    await waitFor(() => expect(channel.pushed.at(-1)).toMatchObject({ event: "snapshot" }));
  });

  test("a message typed while a turn runs waits in the queue and goes out when it settles", async () => {
    const user = userEvent.setup();
    await open();
    act(() => channel.deliver("codex", { seq: 4, method: "turn/started", params: { turn: { id: "turn_2", status: "inProgress" } } }));
    await user.type(screen.getByRole("textbox", { name: "随心输入" }), "and then this{Enter}");
    expect(sendMessage).not.toHaveBeenCalled();
    act(() => channel.deliver("codex", { seq: 5, method: "turn/completed", params: { turn: { id: "turn_2", status: "completed" } } }));
    await waitFor(() => expect(sendMessage).toHaveBeenCalledWith(expect.objectContaining({ input: { threadId: "t1", text: "and then this" } })));
  });

  test("phone: the chat still shows the command block and the bottom toolbar", async () => {
    setViewport(390);
    await open();
    expect(screen.getByTestId("bottom-toolbar")).toBeInTheDocument();
    expect(within(screen.getByTestId("chat-area")).getByTestId("tool-command")).toBeInTheDocument();
  });
});
