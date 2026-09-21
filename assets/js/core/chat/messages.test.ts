import { describe, expect, test } from "vitest";
import { displayCommand, toMessages, userText } from "./messages";
import { emptyView, type ThreadView } from "./thread";
import type { ThreadMessageLike } from "@assistant-ui/react";

const parts = (m: ThreadMessageLike) => m.content as unknown as Record<string, unknown>[];

function view(partial: Partial<ThreadView>): ThreadView {
  return { ...emptyView("thr_1"), ...partial };
}

describe("toMessages", () => {
  test("user items become user messages; a turn's other items one assistant message", () => {
    const msgs = toMessages(
      view({
        turn: { id: "t1", status: "completed" },
        items: [
          { id: "u1", type: "userMessage", turnId: "t1", content: [{ type: "text", text: "run tests" }] },
          { id: "r1", type: "reasoning", turnId: "t1", summary: "thinking about tests" },
          { id: "c1", type: "commandExecution", turnId: "t1", command: "mix test", cwd: "/p", status: "completed", exitCode: 0, aggregatedOutput: "ok\n", durationMs: 1200 },
          { id: "a1", type: "agentMessage", turnId: "t1", text: "All green." },
        ],
      }),
    );
    expect(msgs.map((m) => m.role)).toEqual(["user", "assistant"]);
    expect(msgs[0]!.content).toEqual([{ type: "text", text: "run tests" }]);
    const ps = parts(msgs[1]!);
    expect(ps.map((p) => p["type"])).toEqual(["reasoning", "tool-call", "text"]);
    expect(ps[1]).toMatchObject({ toolName: "commandExecution", toolCallId: "c1", args: { command: "mix test" }, result: { exitCode: 0, output: "ok\n" } });
    expect(msgs[1]!.status).toEqual({ type: "complete", reason: "stop" });
  });

  test("a message from another agent: its name in the metadata, the [agent name] prefix (for the model) stripped", () => {
    const msgs = toMessages(
      view({
        items: [
          { id: "u1", type: "userMessage", turnId: "t1", from: "researcher", content: [{ type: "text", text: "[agent researcher] **done**\n\n- a\n- b" }] },
          { id: "u2", type: "userMessage", turnId: "t1", content: [{ type: "text", text: "[agent researcher] typed by the person, kept" }] },
        ],
      }),
    );
    expect(msgs[0]!.metadata).toMatchObject({ custom: { from: "researcher" } });
    expect(msgs[0]!.content).toEqual([{ type: "text", text: "**done**\n\n- a\n- b" }]);
    expect(msgs[1]!.metadata?.custom?.["from"]).toBeUndefined();
    expect(msgs[1]!.content).toEqual([{ type: "text", text: "[agent researcher] typed by the person, kept" }]);
  });

  test("what an agent's message is (kind) rides in the metadata; consecutive messages from one agent of one kind fold into a single message", () => {
    const from = (id: string, turnId: string, name: string, kind: string | undefined, text: string) => ({
      id,
      type: "userMessage",
      turnId,
      from: name,
      ...(kind ? { kind } : {}),
      content: [{ type: "text", text: `[agent ${name}] ${text}` }],
    });
    const msgs = toMessages(
      view({
        items: [
          from("u1", "t1", "coder-3", "report", "done A"),
          { id: "a1", type: "agentMessage", turnId: "t1", text: "noted" },
          // two steers in a row from the same agent: one labelled block, two paragraphs
          from("u2", "t1", "coder-3", "report", "and B"),
          from("u3", "t1", "coder-3", "report", "and C"),
          // another agent, then the same agent with another kind: their own messages
          from("u4", "t1", "coder-2", "report", "mine"),
          from("u5", "t1", "coder-3", "answer", "reply"),
          // an older item without a kind stays a plain agent message
          from("u6", "t1", "coder-3", undefined, "old"),
        ],
      }),
    );
    expect(msgs.map((m) => [m.id, m.role])).toEqual([
      ["u1", "user"],
      ["turn:t1", "assistant"],
      ["u2", "user"],
      ["u4", "user"],
      ["u5", "user"],
      ["u6", "user"],
    ]);
    expect(msgs[0]!.metadata).toMatchObject({ custom: { from: "coder-3", kind: "report" } });
    expect(msgs[2]!.content).toEqual([
      { type: "text", text: "and B" },
      { type: "text", text: "and C" },
    ]);
    expect(msgs[2]!.metadata).toMatchObject({ custom: { from: "coder-3", kind: "report" } });
    expect(msgs[3]!.content).toEqual([{ type: "text", text: "mine" }]);
    expect(msgs[4]!.metadata).toMatchObject({ custom: { from: "coder-3", kind: "answer" } });
    expect(msgs[5]!.metadata?.custom?.["kind"]).toBeUndefined();
  });

  test("the turn in flight is running; a streaming command has no result yet", () => {
    const msgs = toMessages(
      view({
        turn: { id: "t2", status: "inProgress" },
        items: [
          { id: "u2", type: "userMessage", turnId: "t2", content: [{ type: "text", text: "go" }] },
          { id: "c2", type: "commandExecution", turnId: "t2", command: "sleep 9", status: "inProgress", aggregatedOutput: "partial" },
        ],
      }),
    );
    expect(msgs[1]!.status).toEqual({ type: "running" });
    const tool = parts(msgs[1]!)[0]!;
    expect(tool["result"]).toBeUndefined();
    expect(tool["artifact"]).toBe("partial");
  });

  test("a non-zero exit is an error; interrupted and failed turns are incomplete", () => {
    const failed = toMessages(
      view({
        turn: { id: "t3", status: "failed", error: { message: "model failed" } },
        items: [{ id: "c3", type: "commandExecution", turnId: "t3", command: "x", status: "completed", exitCode: 2 }],
      }),
    );
    expect(parts(failed[0]!)[0]).toMatchObject({ isError: true });
    expect(failed[0]!.status).toEqual({ type: "incomplete", reason: "error", error: "model failed" });

    const interrupted = toMessages(view({ turn: { id: "t4", status: "interrupted" }, items: [{ id: "a4", type: "agentMessage", turnId: "t4", text: "half" }] }));
    expect(interrupted[0]!.status).toEqual({ type: "incomplete", reason: "cancelled" });
  });

  test("unknown item types are kept as data parts; dynamic tools use ns.name", () => {
    const msgs = toMessages(
      view({
        items: [
          { id: "x1", type: "contextCompaction", turnId: "t7" },
          { id: "d1", type: "dynamicToolCall", turnId: "t7", namespace: "builtin", tool: "echo", arguments: { message: "hi" }, status: "completed", success: true, contentItems: [] },
        ],
      }),
    );
    const ps = parts(msgs[0]!);
    // the kernel compacted the context here: a marker, not a tool
    expect(ps[0]).toEqual({ type: "data-compaction", data: { id: "x1" } });
    expect(ps[1]).toMatchObject({ toolName: "builtin.echo", args: { message: "hi" }, result: { success: true } });
    const other = toMessages(view({ items: [{ id: "e1", type: "somethingNew", turnId: "t7", detail: "x" }] }));
    expect(parts(other[0]!)[0]).toMatchObject({ type: "data-item" });
  });

  test("a goal's continuation — a user message the kernel wrote — is a marker in the turn, never the person's bubble", () => {
    const msgs = toMessages(
      view({
        items: [
          { id: "u1", type: "userMessage", turnId: "t7", content: [{ type: "text", text: "do it" }] },
          { id: "a1", type: "agentMessage", turnId: "t7", text: "step one" },
          { id: "u2", type: "userMessage", turnId: "t7", content: [{ type: "text", text: "（目标续跑）Your goal is still active (round 2): ship it\n\nContinue…" }], origin: { kind: "goal", round: 2, objective: "ship it" } },
          { id: "a2", type: "agentMessage", turnId: "t7", text: "step two" },
        ],
      }),
    );
    expect(msgs.map((m) => m.role)).toEqual(["user", "assistant"]);
    const ps = parts(msgs[1]!);
    expect(ps[0]).toMatchObject({ type: "text", text: "step one" });
    expect(ps[1]).toEqual({ type: "data-goal", data: { id: "u2", round: 2, objective: "ship it" } });
    expect(ps[2]).toMatchObject({ type: "text", text: "step two" });
  });

  test("a continuation written before it carried an origin is recognised by its text", () => {
    const text = "（目标续跑）Your goal is still active (round 3): 以「市值排序」为核心的改进路径\n\nContinue working toward it. When it is achieved, call update_goal…";
    const msgs = toMessages(
      view({
        items: [
          { id: "a1", type: "agentMessage", turnId: "t7", text: "step one" },
          { id: "u2", type: "userMessage", turnId: "t7", content: [{ type: "text", text }] },
        ],
      }),
    );
    expect(msgs).toHaveLength(1);
    expect(parts(msgs[0]!)[1]).toEqual({ type: "data-goal", data: { id: "u2", round: 3, objective: "以「市值排序」为核心的改进路径" } });
  });

  test("reasoning lists (summary or full text) become one reasoning part", () => {
    const msgs = toMessages(
      view({
        turn: { id: "t8", status: "completed" },
        items: [
          { id: "r8", type: "reasoning", turnId: "t8", summary: ["first", "second"], content: [] },
          { id: "r9", type: "reasoning", turnId: "t8", summary: [], content: ["raw text"] },
          { id: "r0", type: "reasoning", turnId: "t8", summary: [], content: [] },
        ],
      }),
    );
    const ps = parts(msgs[0]!);
    expect(ps).toEqual([
      { type: "reasoning", text: "first\n\nsecond" },
      { type: "reasoning", text: "raw text" },
    ]);
  });

  test("displayCommand unwraps the login-shell wrapper, keeps anything else", () => {
    expect(displayCommand("/usr/bin/zsh -lc 'ls -la'")).toBe("ls -la");
    expect(displayCommand("bash -lc \"cat 'a b.txt'\"")).toBe("cat 'a b.txt'");
    expect(displayCommand("/bin/sh -c 'echo hi'")).toBe("echo hi");
    expect(displayCommand("ls -la")).toBe("ls -la");
    expect(displayCommand("")).toBe("");
    // the tool call keeps the full command for the tooltip
    const msgs = toMessages(
      view({
        turn: { id: "t9", status: "completed" },
        items: [{ id: "c9", type: "commandExecution", turnId: "t9", command: "/usr/bin/zsh -lc 'mix test'", cwd: "/p", status: "completed", exitCode: 0 }],
      }),
    );
    expect(parts(msgs[0]!)[0]).toMatchObject({ args: { command: "mix test", fullCommand: "/usr/bin/zsh -lc 'mix test'" } });
  });

  test("tool timing and message timing come from the stamps, the turn and token usage", () => {
    const msgs = toMessages(
      view({
        turn: { id: "t10", status: "completed", startedAt: 1_700_000_000, completedAt: 1_700_000_012 },
        tokenUsage: { last: { inputTokens: 100, outputTokens: 240 }, total: { inputTokens: 100, outputTokens: 240 } },
        items: [
          { id: "c10", type: "commandExecution", turnId: "t10", command: "ls", status: "completed", exitCode: 0, startedAtMs: 5000, completedAtMs: 6500 },
          { id: "c11", type: "commandExecution", turnId: "t10", command: "sleep", status: "inProgress", startedAtMs: 7000 },
          { id: "a10", type: "agentMessage", turnId: "t10", text: "done" },
        ],
      }),
    );
    const ps = parts(msgs[0]!);
    expect(ps[0]).toMatchObject({ timing: { startedAt: 5000, completedAt: 6500 } });
    expect(ps[1]).toMatchObject({ timing: { startedAt: 7000 } });
    expect((ps[1] as { timing: { completedAt?: number } }).timing.completedAt).toBeUndefined();
    expect(msgs[0]!.metadata?.timing).toMatchObject({ streamStartTime: 1_700_000_000_000, totalStreamTime: 12_000, tokenCount: 240, toolCallCount: 2 });

    // a running turn has no total yet
    const running = toMessages(view({ turn: { id: "t11", status: "inProgress", startedAt: 1_700_000_100 }, tokenUsage: { last: { outputTokens: 9 } }, items: [{ id: "a11", type: "agentMessage", turnId: "t11", text: "hi" }] }));
    expect(running[0]!.metadata?.timing).toMatchObject({ streamStartTime: 1_700_000_100_000 });
    expect(running[0]!.metadata?.timing?.totalStreamTime).toBeUndefined();

    // every turn the view kept has its own stamps and usage (the kernel puts them on
    // turn/completed): an older turn's badge is not the last turn's numbers
    const two = toMessages(
      view({
        turn: { id: "t13", status: "completed", startedAt: 1_700_000_200, completedAt: 1_700_000_203, usage: { inputTokens: 50, outputTokens: 5, totalTokens: 55 } },
        turns: {
          t12: { id: "t12", status: "completed", startedAt: 1_700_000_000, completedAt: 1_700_000_010, usage: { inputTokens: 1000, cachedInputTokens: 400, outputTokens: 80, reasoningOutputTokens: 30, totalTokens: 1080 } },
          t13: { id: "t13", status: "completed", startedAt: 1_700_000_200, completedAt: 1_700_000_203, usage: { inputTokens: 50, outputTokens: 5, totalTokens: 55 } },
        },
        tokenUsage: { last: { outputTokens: 5 } },
        items: [
          { id: "a12", type: "agentMessage", turnId: "t12", text: "first" },
          { id: "a13", type: "agentMessage", turnId: "t13", text: "second" },
        ],
      }),
    );
    expect(two[0]!.metadata?.timing).toMatchObject({ totalStreamTime: 10_000, tokenCount: 80 });
    expect(two[0]!.metadata?.custom).toMatchObject({ usage: { inputTokens: 1000, cachedInputTokens: 400, outputTokens: 80, reasoningOutputTokens: 30 } });
    expect(two[1]!.metadata?.timing).toMatchObject({ totalStreamTime: 3_000, tokenCount: 5 });

    // the model and level the turn ran on ride along for the badge
    const modelled = toMessages(
      view({
        turn: { id: "t14", status: "completed", startedAt: 1_700_000_300, completedAt: 1_700_000_301, model: "deepseek-flash", modelName: "plus", effort: "low" },
        turns: { t14: { id: "t14", status: "completed", startedAt: 1_700_000_300, completedAt: 1_700_000_301, model: "deepseek-flash", modelName: "plus", effort: "low" } },
        items: [{ id: "a14", type: "agentMessage", turnId: "t14", text: "ok" }],
      }),
    );
    expect(modelled[0]!.metadata?.custom).toMatchObject({ model: { slug: "deepseek-flash", name: "plus", effort: "low" } });
  });

  test("a tool's ask (Context.ask) is a standalone action part on the last message, answered through extras", () => {
    const msgs = toMessages(
      view({
        turn: { id: "t12", status: "inProgress" },
        items: [
          { id: "u12", type: "userMessage", turnId: "t12", content: [{ type: "text", text: "go" }] },
          { id: "a12", type: "agentMessage", turnId: "t12", text: "logging in" },
        ],
        requests: [
          {
            id: 3,
            method: "longx/action/request",
            params: { requestId: 3, itemId: "call_3", turnId: "t12", title: "登录 GitHub", text: "打开链接完成登录", url: "https://x.dev/login", fields: [{ id: "code", label: "验证码" }] },
          },
        ],
      }),
    );
    const ps = parts(msgs[1]!);
    expect(ps.map((p) => p["type"])).toEqual(["text", "tool-call"]);
    expect(ps[1]).toMatchObject({ toolName: "action", toolCallId: "call_3:ask", args: { requestId: "3", title: "登录 GitHub", text: "打开链接完成登录", url: "https://x.dev/login", fields: [{ id: "code", label: "验证码" }] } });
    // assistant-ui only shows the controls on a requires-action message
    expect(msgs[1]!.status).toEqual({ type: "requires-action", reason: "interrupt" });
    // an ask with nothing to hang on yet still gets a place
    const bare = toMessages(view({ turn: { id: "t13", status: "inProgress" }, items: [{ id: "u13", type: "userMessage", turnId: "t13", content: [{ type: "text", text: "go" }] }], requests: [{ id: 4, method: "longx/action/request", params: { requestId: 4, title: "x" } }] }));
    expect(bare).toHaveLength(2);
    expect(parts(bare[1]!)[0]).toMatchObject({ toolName: "action", args: { url: null, fields: [] } });
  });

  test("a user message's images are image parts next to its text", () => {
    const msgs = toMessages({
      ...emptyView("thr_1"),
      items: [{ id: "u13", type: "userMessage", turnId: "t13", content: [{ type: "text", text: "what is this" }, { type: "image", url: "data:image/png;base64,AA" }] }],
    });
    expect(parts(msgs[0]!)).toEqual([
      { type: "text", text: "what is this" },
      { type: "image", image: "data:image/png;base64,AA" },
    ]);
  });

  test("userText joins text parts", () => {
    expect(userText({ id: "u", type: "userMessage", content: [{ type: "text", text: "a" }, { type: "image" }, { type: "text", text: "b" }] })).toBe("ab");
    expect(userText({ id: "u", type: "userMessage", content: "plain" })).toBe("plain");
  });
});

describe("multi-agent", () => {
  const activity = (id: string, kind: string, name = "alpha") => ({ id, type: "subAgentActivity", turnId: "t20", agentPath: `/root/${name}`, agentThreadId: `child-${name}`, kind });

  test("a sub-agent's activities collapse into one `subagent` tool call carrying the child's conversation", () => {
    const child = view({
      threadId: "child-alpha",
      turn: { id: "ct", status: "completed" },
      items: [
        { id: "cc", type: "commandExecution", turnId: "ct", command: "echo alpha", status: "completed", exitCode: 0, aggregatedOutput: "alpha\n" },
        { id: "cm", type: "agentMessage", turnId: "ct", text: "done by alpha" },
      ],
    });
    const msgs = toMessages(
      view({
        turn: { id: "t20", status: "completed" },
        items: [
          { id: "u20", type: "userMessage", turnId: "t20", content: [{ type: "text", text: "spawn alpha" }] },
          activity("act1", "started"),
          { id: "a20", type: "agentMessage", turnId: "t20", text: "waiting" },
          activity("act2", "interacted"),
          activity("act3", "completed"),
        ],
      }),
      { "child-alpha": child },
    );
    const ps = parts(msgs[1]!);
    expect(ps.map((p) => p["type"])).toEqual(["tool-call", "text"]);
    const sub = ps[0] as unknown as { toolCallId: string; toolName: string; args: Record<string, unknown>; result: unknown; messages: { role: string; content: unknown[] }[] };
    expect(sub).toMatchObject({ toolCallId: "child-alpha", toolName: "subagent", args: { name: "alpha", path: "/root/alpha", threadId: "child-alpha", kind: "completed" }, result: { kind: "completed" } });
    expect(sub.messages).toHaveLength(1);
    expect(sub.messages[0]!.role).toBe("assistant");
    expect(sub.messages[0]!.content.map((p) => (p as { type: string }).type)).toEqual(["tool-call", "text"]);
  });

  test("a child asked again in a later turn gets its row there, with the conversation; the earlier row stays as a completed marker", () => {
    const child = view({
      threadId: "child-alpha",
      turn: { id: "ct2", status: "inProgress" },
      items: [
        { id: "cu1", type: "userMessage", turnId: "ct1", content: [{ type: "text", text: "[agent main] first task" }], from: "main" },
        { id: "cm1", type: "agentMessage", turnId: "ct1", text: "first answer" },
        { id: "cu2", type: "userMessage", turnId: "ct2", content: [{ type: "text", text: "[agent main] and more" }], from: "main" },
        { id: "cm2", type: "agentMessage", turnId: "ct2", text: "working…" },
      ],
    });
    const at = (id: string, kind: string, turnId: string) => ({ ...activity(id, kind), turnId });
    const msgs = toMessages(
      view({
        turn: { id: "t22", status: "inProgress" },
        items: [
          { id: "u20", type: "userMessage", turnId: "t20", content: [{ type: "text", text: "spawn alpha" }] },
          at("act1", "started", "t20"),
          { id: "a20", type: "agentMessage", turnId: "t20", text: "sent" },
          at("act2", "completed", "t21"),
          { id: "a21", type: "agentMessage", turnId: "t21", text: "it reported" },
          { id: "u22", type: "userMessage", turnId: "t22", content: [{ type: "text", text: "ask it more" }] },
          at("act3", "interacted", "t22"),
          { id: "a22", type: "agentMessage", turnId: "t22", text: "asked" },
        ],
      }),
      { "child-alpha": child },
    );
    // t20: the spawn's row, completed, no conversation nested (it moved on); t22: the live row with everything
    const first = parts(msgs[1]!)[0] as unknown as { toolCallId: string; args: Record<string, unknown>; result: unknown; messages?: unknown[] };
    expect(first).toMatchObject({ toolCallId: "child-alpha:act1", args: { kind: "completed" }, result: { kind: "completed" } });
    expect(first.messages).toBeUndefined();
    const again = parts(msgs[msgs.length - 1]!)[0] as unknown as { toolCallId: string; args: Record<string, unknown>; result: unknown; messages: { role: string }[] };
    expect(again).toMatchObject({ toolCallId: "child-alpha", args: { kind: "interacted" } });
    expect(again.result).toBeUndefined();
    expect(again.messages.map((m) => m.role)).toEqual(["user", "assistant", "user", "assistant"]);
    // a completion in a turn of its own makes no row
    expect(parts(msgs[2]!).map((p) => p["type"])).toEqual(["text"]);
  });

  test("a sub-agent still working has no result; without its view the call has no messages", () => {
    const msgs = toMessages(view({ turn: { id: "t20", status: "inProgress" }, items: [activity("act1", "started")] }));
    const sub = parts(msgs[0]!)[0]!;
    expect(sub["result"]).toBeUndefined();
    expect(sub["messages"]).toBeUndefined();
    expect(msgs[0]!.status).toEqual({ type: "running" });
  });

  test("a child waiting on the person shows its ask on the sub-agent row; the ask itself is answered inside the child's conversation", () => {
    const child = view({
      threadId: "child-alpha",
      turn: { id: "ct", status: "inProgress" },
      items: [{ id: "cc", type: "commandExecution", turnId: "ct", command: "gh auth login", status: "inProgress" }],
      requests: [{ id: 7, method: "longx/action/request", params: { requestId: 7, itemId: "cc", title: "登录 GitHub" } }],
    });
    const msgs = toMessages(view({ turn: { id: "t20", status: "inProgress" }, items: [activity("act1", "started")] }), { "child-alpha": child });
    const sub = parts(msgs[0]!)[0] as unknown as { args: { request: { title: string } | null }; messages: { content: { type: string; toolName?: string }[] }[] };
    expect(sub.args.request).toEqual({ title: "登录 GitHub" });
    expect(sub.messages.at(-1)!.content.map((p) => p.toolName)).toEqual(["commandExecution", "action"]);
    expect(msgs[0]!.status).toEqual({ type: "running" });
  });
});

test("an ask that carries a generative tree hands the tree to the action part", () => {
  const spec = { $type: "Button", label: "继续", $action: { type: "go" } };
  const msgs = toMessages(
    view({
      turn: { id: "t30", status: "inProgress" },
      items: [{ id: "u30", type: "userMessage", turnId: "t30", content: [{ type: "text", text: "go" }] }],
      requests: [{ id: 9, method: "longx/action/request", params: { requestId: 9, itemId: "p1", title: "继续？", spec } }],
    }),
  );
  const action = parts(msgs.at(-1)!).find((p) => (p as { toolName?: string }).toolName === "action") as unknown as { args: { spec?: unknown } };
  expect(action.args.spec).toEqual(spec);
});

test("a message steered into a running turn splits the turn's assistant message in two, each with an id of its own", () => {
  const view = {
    ...emptyView("thr_1"),
    turn: { id: "turn_1", status: "inProgress" },
    items: [
      { id: "u1", type: "userMessage", turnId: "turn_1", content: [{ type: "text", text: "run it" }] },
      { id: "c1", type: "commandExecution", turnId: "turn_1", command: "sleep 12", status: "completed", exitCode: 0, aggregatedOutput: "" },
      { id: "u2", type: "userMessage", turnId: "turn_1", content: [{ type: "text", text: "also this" }] },
      { id: "m1", type: "agentMessage", turnId: "turn_1", text: "done both" },
    ],
  };
  const messages = toMessages(view);
  expect(messages.map((m) => [m.id, m.role])).toEqual([
    ["u1", "user"],
    ["turn:turn_1", "assistant"],
    ["u2", "user"],
    ["turn:turn_1:1", "assistant"],
  ]);
  // the command is on the first segment, the answer on the second — nothing lost
  expect((messages[1]!.content as readonly { type: string }[]).map((p) => p.type)).toEqual(["tool-call"]);
  expect((messages[3]!.content as readonly { type: string }[]).map((p) => p.type)).toEqual(["text"]);
});
