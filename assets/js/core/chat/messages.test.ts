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
        turn: { id: "t3", status: "failed", error: { message: "codex restarted" } },
        items: [{ id: "c3", type: "commandExecution", turnId: "t3", command: "x", status: "completed", exitCode: 2 }],
      }),
    );
    expect(parts(failed[0]!)[0]).toMatchObject({ isError: true });
    expect(failed[0]!.status).toEqual({ type: "incomplete", reason: "error", error: "codex restarted" });

    const interrupted = toMessages(view({ turn: { id: "t4", status: "interrupted" }, items: [{ id: "a4", type: "agentMessage", turnId: "t4", text: "half" }] }));
    expect(interrupted[0]!.status).toEqual({ type: "incomplete", reason: "cancelled" });
  });

  test("a pending approval rides on its tool call with the three options", () => {
    const msgs = toMessages(
      view({
        turn: { id: "t5", status: "inProgress" },
        items: [{ id: "c5", type: "commandExecution", turnId: "t5", command: "rm -rf build", status: "inProgress" }],
        requests: [{ id: 42, method: "item/commandExecution/requestApproval", params: { requestId: 42, itemId: "c5", command: "rm -rf build" } }],
      }),
    );
    const tool = parts(msgs[0]!)[0] as unknown as { approval: { id: string; options: { id: string }[]; prompt: string } };
    expect(tool.approval.id).toBe("42");
    expect(tool.approval.options.map((o) => o.id)).toEqual(["accept", "accept_for_session", "decline"]);
    expect(tool.approval.prompt).toBe("允许执行这条命令？");
    // assistant-ui only shows approval controls on a requires-action part
    expect(msgs[0]!.status).toEqual({ type: "requires-action", reason: "interrupt" });
  });

  test("an approval whose item has not arrived still gets a place", () => {
    const msgs = toMessages(
      view({
        turn: { id: "t6", status: "inProgress" },
        items: [{ id: "u6", type: "userMessage", turnId: "t6", content: [{ type: "text", text: "go" }] }],
        requests: [{ id: "r1", method: "item/fileChange/requestApproval", params: { requestId: "r1", itemId: "f9" } }],
      }),
    );
    expect(msgs).toHaveLength(2);
    expect(parts(msgs[1]!)[0]).toMatchObject({ toolName: "fileChange", toolCallId: "f9" });
    expect(msgs[1]!.status).toEqual({ type: "requires-action", reason: "interrupt" });
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
    // codex compacted the context here: a marker, not a tool
    expect(ps[0]).toEqual({ type: "data-compaction", data: { id: "x1" } });
    expect(ps[1]).toMatchObject({ toolName: "builtin.echo", args: { message: "hi" }, result: { success: true } });
    const other = toMessages(view({ items: [{ id: "e1", type: "enteredReviewMode", turnId: "t7", review: "x" }] }));
    expect(parts(other[0]!)[0]).toMatchObject({ type: "data-codex" });
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

  test("displayCommand unwraps codex's login-shell wrapper, keeps anything else", () => {
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

    // a running turn has no total yet; an older turn gets no token count (usage is per last turn)
    const running = toMessages(view({ turn: { id: "t11", status: "inProgress", startedAt: 1_700_000_100 }, tokenUsage: { last: { outputTokens: 9 } }, items: [{ id: "a11", type: "agentMessage", turnId: "t11", text: "hi" }] }));
    expect(running[0]!.metadata?.timing).toMatchObject({ streamStartTime: 1_700_000_100_000 });
    expect(running[0]!.metadata?.timing?.totalStreamTime).toBeUndefined();
  });

  test("a pending requestUserInput becomes a standalone question part answered through extras", () => {
    const msgs = toMessages(
      view({
        turn: { id: "t12", status: "inProgress" },
        items: [{ id: "u12", type: "userMessage", turnId: "t12", content: [{ type: "text", text: "go" }] }],
        requests: [
          {
            id: 3,
            method: "item/tool/requestUserInput",
            params: { requestId: 3, itemId: "call_3", turnId: "t12", isBlocking: true, questions: [{ id: "q1", header: "DB", question: "which db?", options: [{ label: "sqlite", description: "" }], isOther: true }] },
          },
        ],
      }),
    );
    const part = parts(msgs[1]!)[0]!;
    expect(part).toMatchObject({ type: "tool-call", toolName: "requestUserInput", toolCallId: "call_3", args: { requestId: "3", questions: [{ id: "q1" }] } });
    expect(msgs[1]!.status).toEqual({ type: "requires-action", reason: "interrupt" });
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

  test("a sub-agent still working has no result; without its view the call has no messages", () => {
    const msgs = toMessages(view({ turn: { id: "t20", status: "inProgress" }, items: [activity("act1", "started")] }));
    const sub = parts(msgs[0]!)[0]!;
    expect(sub["result"]).toBeUndefined();
    expect(sub["messages"]).toBeUndefined();
    expect(msgs[0]!.status).toEqual({ type: "running" });
  });

  test("a child's pending approval rides on the sub-agent call so the parent can answer it", () => {
    const child = view({
      threadId: "child-alpha",
      turn: { id: "ct", status: "inProgress" },
      items: [{ id: "cc", type: "commandExecution", turnId: "ct", command: "rm -rf x", status: "inProgress" }],
      requests: [{ id: 7, method: "item/commandExecution/requestApproval", params: { requestId: 7, itemId: "cc", command: "rm -rf x" } }],
    });
    const msgs = toMessages(view({ turn: { id: "t20", status: "inProgress" }, items: [activity("act1", "started")] }), { "child-alpha": child });
    const sub = parts(msgs[0]!)[0] as unknown as { approval: { id: string; prompt: string } };
    expect(sub.approval.id).toBe("7");
    expect(sub.approval.prompt).toContain("alpha");
    expect(msgs[0]!.status).toEqual({ type: "requires-action", reason: "interrupt" });
  });

  test("collabAgentToolCall becomes a `collab` call naming the agents it talks to", () => {
    const msgs = toMessages(
      view({
        turn: { id: "t20", status: "completed" },
        items: [
          activity("act1", "started"),
          activity("act2", "started", "beta"),
          {
            id: "collab1",
            type: "collabAgentToolCall",
            turnId: "t20",
            tool: "wait",
            status: "completed",
            senderThreadId: "thr_1",
            receiverThreadIds: ["child-alpha", "child-beta"],
            agentsStates: { "child-alpha": { status: "completed", message: "done by alpha" }, "child-beta": { status: "running", message: null } },
            prompt: null,
            model: null,
          },
          { id: "spawn1", type: "collabAgentToolCall", turnId: "t20", tool: "spawnAgent", status: "inProgress", senderThreadId: "thr_1", receiverThreadIds: [], agentsStates: {}, prompt: "read the docs", model: "deepseek-flash" },
          { id: "wait2", type: "collabAgentToolCall", turnId: "t20", tool: "wait", status: "inProgress", senderThreadId: "thr_1", receiverThreadIds: [], agentsStates: {}, prompt: null, model: null },
        ],
      }),
    );
    const ps = parts(msgs[0]!);
    expect(ps.map((p) => p["toolName"])).toEqual(["subagent", "subagent", "collab", "collab", "collab"]);
    // a wait in flight names nobody yet: it waits for every agent so far
    expect(ps[4]).toMatchObject({ args: { tool: "wait", agents: [{ name: "alpha" }, { name: "beta" }] } });
    expect(ps[2]).toMatchObject({
      toolCallId: "collab1",
      // each agent carries its own latest activity too: real codex completes a wait with
      // empty agentsStates, so the sub-agents' activities are what says who is done
      args: { tool: "wait", agents: [{ threadId: "child-alpha", name: "alpha", kind: "started" }, { threadId: "child-beta", name: "beta", kind: "started" }] },
      result: { status: "completed", agentsStates: { "child-alpha": { status: "completed" } } },
    });
    expect(ps[3]).toMatchObject({ args: { tool: "spawnAgent", prompt: "read the docs", model: "deepseek-flash" } });
    expect(ps[3]!["result"]).toBeUndefined();
  });

  test("the turn's plan is a data part at the top of its message", () => {
    const msgs = toMessages(
      view({
        turn: { id: "t21", status: "inProgress" },
        plan: { turnId: "t21", explanation: "delegating", plan: [{ step: "spawn", status: "completed" }, { step: "wait", status: "inProgress" }] },
        items: [
          { id: "u21", type: "userMessage", turnId: "t21", content: [{ type: "text", text: "go" }] },
          { id: "a21", type: "agentMessage", turnId: "t21", text: "on it" },
        ],
      }),
    );
    const ps = parts(msgs[1]!);
    expect(ps[0]).toEqual({ type: "data-plan", data: { explanation: "delegating", steps: [{ step: "spawn", status: "completed" }, { step: "wait", status: "inProgress" }] } });
    // an older turn's message does not show the current plan
    const older = toMessages(view({ turn: { id: "t22", status: "inProgress" }, plan: { turnId: "t22", explanation: null, plan: [{ step: "x", status: "pending" }] }, items: [{ id: "a20", type: "agentMessage", turnId: "t20", text: "old" }] }));
    expect(parts(older[0]!).map((p) => p["type"])).toEqual(["text"]);
  });
});
