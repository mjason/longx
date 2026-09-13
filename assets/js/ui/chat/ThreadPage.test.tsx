import { act, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, test, vi } from "vitest";
import { renderAt, setViewport } from "@/ui/test-utils";
import { _resetFrameStoreForTests } from "@/core/frame";
import { channel, ok, thread } from "@/ui/test-mocks";

vi.mock("@/ash_rpc", async () => (await import("@/ui/test-mocks")).rpcMock());
vi.mock("@/core/socket", async () => (await import("@/ui/test-mocks")).socketMock());
import { answerRequest, listThreads, respond, searchFiles, sendMessage, startThread } from "@/ash_rpc";

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
      expect(sendMessage).toHaveBeenCalledWith(expect.objectContaining({ input: expect.objectContaining({ threadId: "t1", text: "next step", model: "glm-5", sandbox: "workspace_write" }) })),
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

  test("the project route is a new chat: the first message creates the thread (in the picked mode, web search included) and opens it", async () => {
    const user = userEvent.setup();
    const { router } = renderAt("/p/app-1");
    await screen.findByText("让 agent 在这个项目里干活");
    expect(channel.topics.filter((t) => t.startsWith("thread:"))).toEqual([]);
    // web search can only be chosen before the thread exists
    await user.click(screen.getByTestId("mode-picker"));
    const webSearch = await screen.findByRole("switch", { name: /网页搜索/ });
    expect(webSearch).toBeEnabled();
    await user.click(webSearch);
    // so can the sub-agent tools
    const multiAgent = screen.getByRole("switch", { name: /子 agent/ });
    expect(multiAgent).toBeChecked();
    await user.click(multiAgent);
    await user.keyboard("{Escape}");
    await user.type(screen.getByRole("textbox", { name: "随心输入" }), "start here{Enter}");
    await waitFor(() => expect(startThread).toHaveBeenCalledWith(expect.objectContaining({ input: expect.objectContaining({ projectId: "id-1", webSearch: false, multiAgent: false, sandbox: "workspace_write" }) })));
    await waitFor(() => expect(sendMessage).toHaveBeenCalledWith(expect.objectContaining({ input: expect.objectContaining({ threadId: "t2", text: "start here" }) })));
    await waitFor(() => expect(router.state.location.pathname).toBe("/p/app-1/t/t2"));
  });

  test("the access mode is picked in the composer rail and rides on the next message", async () => {
    const user = userEvent.setup();
    await open();
    await user.click(screen.getByTestId("mode-picker"));
    // an existing thread's web search is fixed
    expect(await screen.findByRole("switch", { name: /网页搜索/ })).toBeDisabled();
    await user.click(await screen.findByRole("radio", { name: "完全访问（危险）" }));
    await user.click(screen.getByRole("radio", { name: "从不询问" }));
    await user.keyboard("{Escape}");
    expect(screen.getByTestId("mode-picker")).toHaveTextContent("完全访问");
    await user.type(screen.getByRole("textbox", { name: "随心输入" }), "go wild{Enter}");
    await waitFor(() =>
      expect(sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({ input: expect.objectContaining({ text: "go wild", sandbox: "danger_full_access", approvalPolicy: "never", networkAccess: false }) }),
      ),
    );
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
    await waitFor(() => expect(sendMessage).toHaveBeenCalledWith(expect.objectContaining({ input: expect.objectContaining({ threadId: "t1", text: "and then this" }) })));
  });

  test("a sub-agent joins its own thread: its conversation nests under the parent, its approval is answered there, the plan shows", async () => {
    const user = userEvent.setup();
    await open();
    const child = "thr_1-alpha";
    act(() => {
      channel.deliverTo("thread:thr_1", "codex", { seq: 4, method: "turn/started", params: { turn: { id: "turn_2", status: "inProgress" } } });
      channel.deliverTo("thread:thr_1", "codex", { seq: 5, method: "turn/plan/updated", params: { turnId: "turn_2", explanation: "delegating", plan: [{ step: "spawn alpha", status: "completed" }, { step: "wait for alpha", status: "inProgress" }] } });
      channel.deliverTo("thread:thr_1", "codex", { seq: 6, method: "item/completed", params: { turnId: "turn_2", item: { id: "act_alpha_started", type: "subAgentActivity", agentPath: "/root/alpha", agentThreadId: child, kind: "started" } } });
    });
    // the parent's activity opened the child's channel
    await waitFor(() => expect(channel.topics).toContain(`thread:${child}`));
    act(() =>
      channel.replyTo(`thread:${child}`, "ok", {
        thread_id: child,
        seq: 2,
        thread: null,
        turn: { id: "turn_2-alpha", status: "inProgress" },
        status: null,
        token_usage: null,
        plan: null,
        items: [{ id: "cmd_alpha", type: "commandExecution", turnId: "turn_2-alpha", command: "echo alpha", cwd: "/p", status: "inProgress" }],
        pending_requests: [{ id: 9, method: "item/commandExecution/requestApproval", params: { requestId: 9, itemId: "cmd_alpha", threadId: child, command: "echo alpha" } }],
      }),
    );
    expect(screen.getByTestId("plan")).toHaveTextContent("wait for alpha");
    const sub = screen.getByTestId("tool-subagent");
    expect(sub).toHaveTextContent("alpha");
    expect(within(sub).getByTestId("subagent-messages")).toHaveTextContent("echo alpha");
    expect(screen.getByTestId("turn-bar")).toHaveTextContent("等待审批");
    await user.click(screen.getAllByRole("button", { name: "允许" })[0]!);
    await waitFor(() => expect(respond).toHaveBeenCalledWith(expect.objectContaining({ input: { threadId: "t1", requestId: "9", decision: "accept" } })));

    act(() => {
      channel.deliverTo(`thread:${child}`, "codex", { seq: 3, method: "serverRequest/resolved", params: { requestId: 9 } });
      channel.deliverTo(`thread:${child}`, "codex", { seq: 4, method: "item/completed", params: { turnId: "turn_2-alpha", item: { id: "cmd_alpha", type: "commandExecution", command: "echo alpha", cwd: "/p", status: "completed", exitCode: 0, aggregatedOutput: "alpha\n" } } });
      channel.deliverTo(`thread:${child}`, "codex", { seq: 5, method: "item/completed", params: { turnId: "turn_2-alpha", item: { id: "msg_alpha", type: "agentMessage", text: "done by alpha" } } });
      channel.deliverTo(`thread:${child}`, "codex", { seq: 6, method: "turn/completed", params: { turn: { id: "turn_2-alpha", status: "completed" } } });
      channel.deliverTo("thread:thr_1", "codex", { seq: 7, method: "item/completed", params: { turnId: "turn_2", item: { id: "act_alpha_done", type: "subAgentActivity", agentPath: "/root/alpha", agentThreadId: child, kind: "completed" } } });
    });
    // finished, the row folds like any tool; its conversation is a click away
    expect(screen.getByText("子 agent 完成")).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: /子 agent 完成/ }));
    expect(screen.getByText("done by alpha")).toBeInTheDocument();
  });

  test("the composer rail shows how full the model's context is, from codex's token usage", async () => {
    await open();
    expect(screen.queryByLabelText("上下文用量")).not.toBeInTheDocument();
    act(() =>
      channel.deliver("codex", {
        seq: 4,
        method: "thread/tokenUsage/updated",
        params: { turnId: "turn_1", tokenUsage: { modelContextWindow: 128000, last: { inputTokens: 30000, cachedInputTokens: 2000, outputTokens: 2000, reasoningOutputTokens: 500, totalTokens: 32000 }, total: { inputTokens: 30000, cachedInputTokens: 2000, outputTokens: 2000, reasoningOutputTokens: 500, totalTokens: 32000 } } },
      }),
    );
    expect(screen.getByLabelText("上下文用量")).toHaveTextContent("25%");
  });

  test("@ in the composer offers the project's files; the pick is a path in the text, a chip in the message", async () => {
    vi.mocked(searchFiles).mockResolvedValue(ok([{ path: "lib/longx/gateway.ex", fileName: "gateway.ex", matchType: "file", root: "/srv/app-1", score: 9, indices: null }]) as never);
    const user = userEvent.setup();
    const r = renderAt("/p/app-1/t/t1");
    await waitFor(() => expect(channel.topics).toContain("thread:thr_1"));
    act(() => channel.reply("ok", { ...snapshot, items: [{ id: "u1", type: "userMessage", turnId: "turn_1", content: [{ type: "text", text: "read @lib/a.ex first" }] }] }));
    // a mention already in the history is a chip
    const chip = await screen.findByText("lib/a.ex");
    expect(chip.closest("[data-slot=directive-text-chip]")).not.toBeNull();

    const box = screen.getByRole("textbox", { name: "随心输入" });
    await user.type(box, "look at @gat");
    // the popover asks codex's index (debounced) and lists the matches
    await user.click(await screen.findByRole("option", { name: /gateway\.ex/ }));
    expect(searchFiles).toHaveBeenCalledWith(expect.objectContaining({ input: { id: "id-1", query: "gat" } }));
    expect(box).toHaveValue("look at @lib/longx/gateway.ex ");
    await user.type(box, "{Enter}");
    await waitFor(() => expect(sendMessage).toHaveBeenCalledWith(expect.objectContaining({ input: expect.objectContaining({ text: "look at @lib/longx/gateway.ex" }) })));
    r.unmount();
  });

  test("renderers: fenced code highlights with shiki, a mermaid fence is a diagram, reasoning streams word by word then settles to markdown", async () => {
    const r = renderAt("/p/app-1/t/t1");
    await waitFor(() => expect(channel.topics).toContain("thread:thr_1"));
    act(() =>
      channel.reply("ok", {
        ...snapshot,
        turn: { id: "turn_1", status: "inProgress" },
        items: [
          { id: "u1", type: "userMessage", turnId: "turn_1", content: [{ type: "text", text: "draw it" }] },
          { id: "r1", type: "reasoning", turnId: "turn_1", summary: ["first the schema then the diagram"], content: [] },
        ],
      }),
    );
    await screen.findByText("draw it");
    // the turn is running and reasoning is what streams: word by word (tinted, caret)
    expect(document.querySelector("[data-slot=streaming-text]")).toHaveTextContent("schema");
    act(() => {
      channel.deliver("codex", { seq: 4, method: "item/completed", params: { turnId: "turn_1", item: { id: "a1", type: "agentMessage", text: "```elixir\ndefmodule A do\nend\n```\n\n```mermaid\ngraph TD; A-->B;\n```\n" } } });
      channel.deliver("codex", { seq: 5, method: "turn/completed", params: { turn: { id: "turn_1", status: "completed" } } });
    });
    await waitFor(() => expect(document.querySelector("[data-slot=streaming-text]")).toBeNull());
    // settled, the disclosure folds; opened again it is markdown
    await userEvent.click(screen.getByRole("button", { name: /思考/ }));
    expect(await screen.findByText("first the schema then the diagram")).toBeInTheDocument();
    // code goes through the shiki highlighter (plain until tokenised), mermaid through the diagram element
    await waitFor(() => expect(document.querySelector(".aui-shiki-base")).toHaveTextContent("defmodule A do"));
    await waitFor(() => expect(document.querySelector("[data-slot^=mermaid-]")).not.toBeNull());
    expect(document.querySelector(".aui-shiki-base")?.textContent).not.toContain("graph TD");
    r.unmount();
  });

  test("phone: the chat still shows the command block and the bottom toolbar", async () => {
    setViewport(390);
    await open();
    expect(screen.getByTestId("bottom-toolbar")).toBeInTheDocument();
    expect(within(screen.getByTestId("chat-area")).getByTestId("tool-command")).toBeInTheDocument();
  });
});
