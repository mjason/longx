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
    expect(ps[0]).toMatchObject({ type: "data-codex" });
    expect(ps[1]).toMatchObject({ toolName: "builtin.echo", args: { message: "hi" }, result: { success: true } });
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
