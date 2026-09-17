import { describe, expect, test, vi } from "vitest";
import { createMessageQueue } from "@assistant-ui/react";
import { buildAdapter, textOf } from "./adapter";
import { emptyView } from "./thread";

vi.mock("@/ash_rpc", () => ({
  sendMessage: vi.fn(async () => ({ success: true, data: { id: "turn-row" } })),
  interruptTurn: vi.fn(async () => ({ success: true, data: null })),
  respond: vi.fn(async () => ({ success: true, data: null })),
  answerRequest: vi.fn(async () => ({ success: true, data: null })),
  approveReview: vi.fn(async () => ({ success: true, data: null })),
  setGoal: vi.fn(async () => ({ success: true, data: { objective: "x", status: "active" } })),
  retractTurn: vi.fn(async () => ({ success: true, data: { text: "look at it" } })),
  steerTurn: vi.fn(async () => ({ success: true, data: { codexTurnId: "turn_9" } })),
}));
import { answerRequest, approveReview, interruptTurn, respond, retractTurn, sendMessage, setGoal, steerTurn } from "@/ash_rpc";

const target = { threadId: "row-1", codexThreadId: "thr_1" };
const append = (text: string) =>
  ({
    role: "user",
    content: [{ type: "text", text }],
    parentId: null,
    sourceId: null,
    runConfig: undefined,
  }) as never;
const base = (text: string) => ({
  role: "user",
  content: [{ type: "text", text }],
  parentId: null,
  sourceId: null,
  runConfig: undefined,
});

describe("chat adapter", () => {
  test("onNew sends the text (and the chosen model) as a turn", async () => {
    const adapter = buildAdapter({
      target,
      view: emptyView("thr_1"),
      model: "glm-5",
    });
    await adapter.onNew(append("  hello  "));
    expect(sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({
        input: { threadId: "row-1", text: "hello", model: "glm-5" },
      }),
    );
    expect(adapter.isRunning).toBe(false);
  });

  test("onNew sends the picked reasoning level with the turn", async () => {
    const adapter = buildAdapter({
      target,
      view: emptyView("thr_1"),
      model: null,
      effort: "max",
    });
    await adapter.onNew(append("think hard"));
    expect(sendMessage).toHaveBeenLastCalledWith(
      expect.objectContaining({
        input: { threadId: "row-1", text: "think hard", effort: "max" },
      }),
    );
  });

  test("attachments: images go as data urls, text files are appended to the message", async () => {
    const adapter = buildAdapter({
      target,
      view: emptyView("thr_1"),
      model: null,
    });
    const message = {
      ...base("see"),
      attachments: [
        {
          id: "a1",
          type: "image",
          name: "shot.png",
          contentType: "image/png",
          status: { type: "complete" },
          content: [{ type: "image", image: "data:image/png;base64,AAAA" }],
        },
        {
          id: "a2",
          type: "document",
          name: "notes.txt",
          contentType: "text/plain",
          status: { type: "complete" },
          content: [
            {
              type: "text",
              text: "<attachment name=notes.txt>\nhi\n</attachment>",
            },
          ],
        },
      ],
    };
    await adapter.onNew(message as never);
    expect(sendMessage).toHaveBeenLastCalledWith(
      expect.objectContaining({
        input: {
          threadId: "row-1",
          text: "see\n\n<attachment name=notes.txt>\nhi\n</attachment>",
          images: ["data:image/png;base64,AAAA"],
        },
      }),
    );
  });

  test("an image alone is a message too", async () => {
    const adapter = buildAdapter({
      target,
      view: emptyView("thr_1"),
      model: null,
    });
    const message = {
      ...base(""),
      attachments: [
        {
          id: "a1",
          type: "image",
          name: "s.png",
          contentType: "image/png",
          status: { type: "complete" },
          content: [{ type: "image", image: "data:x" }],
        },
      ],
    };
    await adapter.onNew(message as never);
    expect(sendMessage).toHaveBeenLastCalledWith(
      expect.objectContaining({
        input: { threadId: "row-1", text: "", images: ["data:x"] },
      }),
    );
  });

  test("the attachment and dictation adapters given are handed to the runtime", () => {
    const attachments = { accept: "image/*" } as never;
    const dictation = { listen: () => ({}) } as never;
    const adapter = buildAdapter({
      target,
      view: emptyView("thr_1"),
      model: null,
      attachments,
      dictation,
    });
    expect(adapter.adapters?.attachments).toBe(attachments);
    expect(adapter.adapters?.dictation).toBe(dictation);
  });

  test("the access mode rides on every message (the backend only records a change)", async () => {
    const adapter = buildAdapter({
      target,
      view: emptyView("thr_1"),
      model: null,
      mode: {
        sandbox: "read_only",
        approvalPolicy: "never",
        networkAccess: true,
        webSearch: true,
        multiAgent: true,
        autoReview: true,
      },
    });
    await adapter.onNew(append("look"));
    expect(sendMessage).toHaveBeenLastCalledWith(
      expect.objectContaining({
        input: {
          threadId: "row-1",
          text: "look",
          sandbox: "read_only",
          approvalPolicy: "never",
          networkAccess: true,
        },
      }),
    );
  });

  test("onNew while a turn runs steers the message into it; a turn that ended meanwhile makes it a new turn", async () => {
    vi.mocked(sendMessage).mockClear();
    const running = buildAdapter({
      target,
      view: { ...emptyView("thr_1"), turn: { id: "turn_9", status: "inProgress" } },
      model: null,
    });
    await running.onNew({ role: "user", content: [{ type: "text", text: "also this" }], parentId: null, sourceId: null, runConfig: {} } as never);
    expect(steerTurn).toHaveBeenCalledWith(expect.objectContaining({ input: { threadId: "row-1", text: "also this" } }));
    expect(sendMessage).not.toHaveBeenCalled();

    // codex says the turn is over: the message becomes a turn of its own
    vi.mocked(steerTurn).mockResolvedValueOnce({ success: false, errors: [{ type: "invalid", message: "not_running", shortMessage: "not_running", vars: {}, fields: ["threadId"], path: [], details: {} }] } as never);
    await running.onNew({ role: "user", content: [{ type: "text", text: "late" }], parentId: null, sourceId: null, runConfig: {} } as never);
    expect(sendMessage).toHaveBeenCalledWith(expect.objectContaining({ input: expect.objectContaining({ text: "late" }) }));
  });

  test("onCancel interrupts the turn in flight only", async () => {
    const idle = buildAdapter({
      target,
      view: emptyView("thr_1"),
      model: null,
    });
    await idle.onCancel!();
    expect(interruptTurn).not.toHaveBeenCalled();

    const running = buildAdapter({
      target,
      view: {
        ...emptyView("thr_1"),
        turn: { id: "turn_9", status: "inProgress" },
      },
      model: null,
    });
    expect(running.isRunning).toBe(true);
    await running.onCancel!();
    expect(interruptTurn).toHaveBeenCalledWith(
      expect.objectContaining({
        input: { threadId: "row-1", codexTurnId: "turn_9" },
      }),
    );
  });

  test("onCancel while the turn did no I/O retracts it and hands the text back to the composer; once something ran, or waits to, it only interrupts", async () => {
    vi.mocked(interruptTurn).mockClear();
    const onRetract = vi.fn();
    const untouched = buildAdapter({
      target,
      view: {
        ...emptyView("thr_1"),
        turn: { id: "turn_9", status: "inProgress" },
        items: [{ id: "u9", type: "userMessage", turnId: "turn_9", content: [{ type: "text", text: "look at it" }] }],
      },
      model: null,
      onRetract,
    });
    await untouched.onCancel!();
    expect(retractTurn).toHaveBeenCalledWith(expect.objectContaining({ input: { threadId: "row-1", codexTurnId: "turn_9" } }));
    expect(onRetract).toHaveBeenCalledWith("look at it");
    expect(interruptTurn).not.toHaveBeenCalled();

    // thinking and a half-said answer are words, not side effects: still taken back
    const answering = buildAdapter({
      target,
      view: {
        ...emptyView("thr_1"),
        turn: { id: "turn_9", status: "inProgress" },
        items: [
          { id: "u9", type: "userMessage", turnId: "turn_9", content: [{ type: "text", text: "look at it" }] },
          { id: "r9", type: "reasoning", turnId: "turn_9", summary: ["thinking"] },
          { id: "m9", type: "agentMessage", turnId: "turn_9", text: "Let me" },
        ],
      },
      model: null,
      onRetract,
    });
    await answering.onCancel!();
    expect(interruptTurn).not.toHaveBeenCalled();
    expect(onRetract).toHaveBeenCalledTimes(2);

    // a command ran: only an interrupt
    const ran = buildAdapter({
      target,
      view: {
        ...emptyView("thr_1"),
        turn: { id: "turn_9", status: "inProgress" },
        items: [
          { id: "u9", type: "userMessage", turnId: "turn_9", content: [{ type: "text", text: "look at it" }] },
          { id: "c9", type: "commandExecution", turnId: "turn_9", command: "ls", status: "inProgress" },
        ],
      },
      model: null,
      onRetract,
    });
    await ran.onCancel!();
    expect(interruptTurn).toHaveBeenCalledTimes(1);
    expect(onRetract).toHaveBeenCalledTimes(2);

    // a request waiting on the person (a permission asked for): the same
    const asking = buildAdapter({
      target,
      view: {
        ...emptyView("thr_1"),
        turn: { id: "turn_9", status: "inProgress" },
        items: [{ id: "u9", type: "userMessage", turnId: "turn_9", content: [{ type: "text", text: "look at it" }] }],
        requests: [{ id: 7, method: "item/permissions/requestApproval", params: { threadId: "thr_1", turnId: "turn_9", permissions: {} } }],
      },
      model: null,
      onRetract,
    });
    await asking.onCancel!();
    expect(interruptTurn).toHaveBeenCalledTimes(2);
    expect(onRetract).toHaveBeenCalledTimes(2);
  });

  test("an approval answer goes back as codex's request id and our decision", async () => {
    const view = {
      ...emptyView("thr_1"),
      requests: [
        {
          id: 42,
          method: "item/commandExecution/requestApproval",
          params: { requestId: 42, itemId: "c1" },
        },
      ],
    };
    const adapter = buildAdapter({ target, view, model: null });
    await adapter.onRespondToToolApproval!({
      approvalId: "42",
      approved: true,
      optionId: "accept_for_session",
    });
    expect(respond).toHaveBeenCalledWith(
      expect.objectContaining({
        input: {
          threadId: "row-1",
          requestId: "42",
          decision: "accept_for_session",
        },
      }),
    );
    await adapter.onRespondToToolApproval!({
      approvalId: "42",
      approved: false,
    });
    expect(respond).toHaveBeenLastCalledWith(
      expect.objectContaining({
        input: expect.objectContaining({ decision: "decline" }),
      }),
    );
  });

  test("a dirty tree asks the page what to do, then resends with the answer", async () => {
    const dirty = {
      success: false,
      errors: [
        {
          type: "dirty_tree",
          message: "dirty",
          shortMessage: "dirty",
          vars: {},
          fields: [],
          path: [],
          details: { changes: [{ path: "a.txt", status: "modified" }] },
        },
      ],
    };
    vi.mocked(sendMessage).mockResolvedValueOnce(dirty as never);
    const onDirtyTree = vi.fn(async () => "commit" as const);
    const adapter = buildAdapter({
      target,
      view: emptyView("thr_1"),
      model: null,
      onDirtyTree,
    });
    await adapter.onNew(append("go"));
    expect(onDirtyTree).toHaveBeenCalledWith([
      { path: "a.txt", status: "modified" },
    ]);
    expect(sendMessage).toHaveBeenLastCalledWith(
      expect.objectContaining({
        input: { threadId: "row-1", text: "go", dirty: "commit" },
      }),
    );

    // declining leaves the message unsent, without an error
    vi.mocked(sendMessage).mockResolvedValueOnce(dirty as never);
    const cancel = buildAdapter({
      target,
      view: emptyView("thr_1"),
      model: null,
      onDirtyTree: async () => null,
    });
    const before = vi.mocked(sendMessage).mock.calls.length;
    await expect(cancel.onNew(append("go"))).resolves.toBeUndefined();
    expect(vi.mocked(sendMessage).mock.calls.length).toBe(before + 1);
  });

  test("without a thread, the first message creates one and lands there", async () => {
    const createThread = vi.fn(async () => ({
      threadId: "row-new",
      codexThreadId: "thr_new",
    }));
    const onSent = vi.fn();
    const adapter = buildAdapter({
      target: null,
      view: emptyView(""),
      model: null,
      createThread,
      onSent,
    });
    expect(adapter.messages).toEqual([]);
    await adapter.onNew(append("first"));
    expect(createThread).toHaveBeenCalled();
    expect(sendMessage).toHaveBeenLastCalledWith(
      expect.objectContaining({
        input: { threadId: "row-new", text: "first" },
      }),
    );
    expect(onSent).toHaveBeenCalledWith({
      threadId: "row-new",
      codexThreadId: "thr_new",
    });
  });

  test("loading, send-disabled, refetch, thread list, queue and extras pass through to the runtime", async () => {
    const refetch = vi.fn(async () => {});
    const threadList = { threadId: "row-1", threads: [] };
    const queue = createMessageQueue({ run: () => {} }).adapter;
    const adapter = buildAdapter({
      target,
      view: emptyView("thr_1"),
      model: null,
      loading: true,
      sendDisabled: true,
      refetch,
      threadList,
      queue,
    });
    expect(adapter.isLoading).toBe(true);
    expect(adapter.isSendDisabled).toBe(true);
    expect(adapter.adapters?.threadList).toBe(threadList);
    // the queue adapter is what lets the composer send while a turn runs
    expect(adapter.queue).toBe(queue);
    await adapter.onRefetchThread!();
    expect(refetch).toHaveBeenCalled();

    const extras = adapter.extras as {
      answerRequest: (
        id: string,
        answers: Record<string, string[]>,
      ) => Promise<void>;
    };
    await extras.answerRequest("3", { q1: ["sqlite"] });
    expect(answerRequest).toHaveBeenCalledWith(
      expect.objectContaining({
        input: {
          threadId: "row-1",
          requestId: "3",
          answers: { q1: { answers: ["sqlite"] } },
        },
      }),
    );
  });

  test("a message naming skills ($name) sends them as skill inputs next to the text", async () => {
    const skills = [{ name: "docs", description: "d", shortDescription: null, path: "/p/.agents/skills/docs/SKILL.md", enabled: true }];
    const adapter = buildAdapter({ target, view: emptyView("thr_1"), model: null, skills });
    await adapter.onNew!(append("write it with $docs please"));
    expect(sendMessage).toHaveBeenLastCalledWith(
      expect.objectContaining({ input: expect.objectContaining({ text: "write it with $docs please", skills: [{ name: "docs", path: "/p/.agents/skills/docs/SKILL.md" }] }) }),
    );
    // none named: no skills field at all
    await adapter.onNew!(append("plain"));
    expect((vi.mocked(sendMessage).mock.calls.at(-1)![0] as { input: Record<string, unknown> }).input).not.toHaveProperty("skills");
  });

  test("a message that is `/goal <objective>` sets the thread's goal instead of being sent (a new chat gets its thread first)", async () => {
    vi.mocked(sendMessage).mockClear();
    const adapter = buildAdapter({ target, view: emptyView("thr_1"), model: null });
    await adapter.onNew!(append("/goal 简单写一个 hello"));
    expect(setGoal).toHaveBeenCalledWith(expect.objectContaining({ input: { threadId: "row-1", objective: "简单写一个 hello" } }));
    expect(sendMessage).not.toHaveBeenCalled();

    const createThread = vi.fn(async () => ({ threadId: "row-9", codexThreadId: "thr_9" }));
    const fresh = buildAdapter({ target: null, view: emptyView(""), model: null, createThread });
    await fresh.onNew!(append("/goal 跑通回测"));
    expect(createThread).toHaveBeenCalled();
    expect(setGoal).toHaveBeenLastCalledWith(expect.objectContaining({ input: { threadId: "row-9", objective: "跑通回测" } }));
  });

  test("extras.approveDeniedReview overrides a denied automatic review on the thread row", async () => {
    const adapter = buildAdapter({ target, view: emptyView("thr_1"), model: null });
    const extras = adapter.extras as { approveDeniedReview: (id: string) => Promise<void> };
    await extras.approveDeniedReview("rev-1");
    expect(approveReview).toHaveBeenCalledWith(expect.objectContaining({ input: { threadId: "row-1", reviewId: "rev-1" } }));
  });

  test("textOf joins text parts and trims", () => {
    expect(textOf(append(" a "))).toBe("a");
  });
});

describe("sub-agents", () => {
  test("the children's views nest into the parent's messages and a child's approval is answered on the parent thread", async () => {
    const parent = {
      ...emptyView("thr_1"),
      turn: { id: "t1", status: "inProgress" },
      items: [
        {
          id: "act1",
          type: "subAgentActivity",
          turnId: "t1",
          agentPath: "/root/alpha",
          agentThreadId: "child-alpha",
          kind: "started",
        },
      ],
    };
    const child = {
      ...emptyView("child-alpha"),
      turn: { id: "ct", status: "inProgress" },
      items: [
        {
          id: "cc",
          type: "commandExecution",
          turnId: "ct",
          command: "rm -rf x",
          status: "inProgress",
        },
      ],
      requests: [
        {
          id: 7,
          method: "item/commandExecution/requestApproval",
          params: { requestId: 7, itemId: "cc" },
        },
      ],
    };
    const adapter = buildAdapter({
      target,
      view: parent,
      model: null,
      subviews: { "child-alpha": child },
    });
    const sub = (
      adapter.messages![0]!.content as unknown as {
        toolName: string;
        messages?: unknown[];
        approval?: { id: string };
      }[]
    )[0]!;
    expect(sub.toolName).toBe("subagent");
    expect(sub.messages).toHaveLength(1);
    await adapter.onRespondToToolApproval!({
      approvalId: sub.approval!.id,
      approved: true,
      optionId: "accept",
    });
    expect(respond).toHaveBeenLastCalledWith(
      expect.objectContaining({
        input: { threadId: "row-1", requestId: "7", decision: "accept" },
      }),
    );
  });
});
