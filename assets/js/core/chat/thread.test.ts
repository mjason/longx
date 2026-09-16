import { describe, expect, test } from "vitest";
import { applyEvent, fromSnapshot, runningTurnId, type ThreadSnapshot } from "./thread";

const snapshot: ThreadSnapshot = {
  seq: 10,
  thread_id: "thr_1",
  thread: { id: "thr_1" },
  turn: { id: "turn_1", status: "completed" },
  status: null,
  token_usage: null,
  items: [
    { id: "u1", type: "userMessage", turnId: "turn_1", content: [{ type: "text", text: "hi" }] },
    { id: "a1", type: "agentMessage", turnId: "turn_1", text: "hello" },
  ],
  pending_requests: [],
};

describe("thread view", () => {
  test("events at or before the snapshot's seq are ignored; later ones advance it", () => {
    const v = fromSnapshot(snapshot);
    expect(applyEvent(v, { seq: 10, method: "turn/started", params: { turn: { id: "x" } } })).toBe(v);
    const v2 = applyEvent(v, { seq: 11, method: "turn/started", params: { turn: { id: "turn_2", status: "inProgress" } } });
    expect(v2.seq).toBe(11);
    expect(runningTurnId(v2)).toBe("turn_2");
    expect(runningTurnId(v)).toBeNull();
  });

  test("reasoning summary/content are lists; deltas address an entry by index (like the Store)", () => {
    let v = fromSnapshot(snapshot);
    v = applyEvent(v, { seq: 11, method: "item/started", params: { turnId: "turn_2", item: { id: "r1", type: "reasoning", summary: [], content: [] } } });
    v = applyEvent(v, { seq: 12, method: "item/reasoning/summaryTextDelta", params: { itemId: "r1", delta: "th", summaryIndex: 0 } });
    v = applyEvent(v, { seq: 13, method: "item/reasoning/summaryTextDelta", params: { itemId: "r1", delta: "ink", summaryIndex: 0 } });
    v = applyEvent(v, { seq: 14, method: "item/reasoning/summaryTextDelta", params: { itemId: "r1", delta: "more", summaryIndex: 1 } });
    v = applyEvent(v, { seq: 15, method: "item/reasoning/textDelta", params: { itemId: "r1", delta: "raw", contentIndex: 0 } });
    expect(v.items.at(-1)).toMatchObject({ id: "r1", summary: ["think", "more"], content: ["raw"] });
    // a delta without an index extends the last entry
    v = applyEvent(v, { seq: 16, method: "item/reasoning/textDelta", params: { itemId: "r1", delta: "!" } });
    expect(v.items.at(-1)).toMatchObject({ content: ["raw!"] });
  });

  test("items are stamped with the client clock when they start and complete", () => {
    let v = fromSnapshot(snapshot);
    v = applyEvent(v, { seq: 11, method: "item/started", params: { turnId: "turn_2", item: { id: "c1", type: "commandExecution", command: "ls" } } }, 1000);
    expect(v.items.at(-1)).toMatchObject({ id: "c1", startedAtMs: 1000 });
    v = applyEvent(v, { seq: 12, method: "item/completed", params: { turnId: "turn_2", item: { id: "c1", type: "commandExecution", command: "ls", status: "completed", exitCode: 0 } } }, 1800);
    expect(v.items.at(-1)).toMatchObject({ id: "c1", startedAtMs: 1000, completedAtMs: 1800, exitCode: 0 });
    // snapshot items carry no client stamps
    expect(v.items[1]).not.toHaveProperty("startedAtMs");
  });

  test("items start, stream deltas, complete (replace), in order", () => {
    let v = fromSnapshot(snapshot);
    v = applyEvent(v, { seq: 11, method: "item/started", params: { turnId: "turn_2", item: { id: "a2", type: "agentMessage", text: "" } } });
    v = applyEvent(v, { seq: 12, method: "item/agentMessage/delta", params: { itemId: "a2", delta: "Hel" } });
    v = applyEvent(v, { seq: 13, method: "item/agentMessage/delta", params: { itemId: "a2", delta: "lo" } });
    expect(v.items.at(-1)).toMatchObject({ id: "a2", turnId: "turn_2", text: "Hello" });
    v = applyEvent(v, { seq: 14, method: "item/completed", params: { turnId: "turn_2", item: { id: "a2", type: "agentMessage", text: "Hello!" } } });
    expect(v.items.map((i) => i.id)).toEqual(["u1", "a1", "a2"]);
    expect(v.items.at(-1)!["text"]).toBe("Hello!");
  });

  test("a delta for an unseen item creates a placeholder; command output accumulates", () => {
    let v = fromSnapshot(snapshot);
    v = applyEvent(v, { seq: 11, method: "item/commandExecution/outputDelta", params: { itemId: "c1", delta: "line 1\n" } });
    v = applyEvent(v, { seq: 12, method: "item/commandExecution/outputDelta", params: { itemId: "c1", delta: "line 2\n" } });
    expect(v.items.at(-1)).toMatchObject({ id: "c1", type: "unknown", aggregatedOutput: "line 1\nline 2\n" });
  });

  test("server requests wait until resolved", () => {
    let v = fromSnapshot(snapshot);
    v = applyEvent(v, { seq: 11, method: "item/commandExecution/requestApproval", params: { requestId: 7, itemId: "c1", command: "rm -rf x" } });
    expect(v.requests).toHaveLength(1);
    expect(v.requests[0]).toMatchObject({ id: 7, method: "item/commandExecution/requestApproval" });
    // a repeat of the same request (a rejoin) is not a second one
    v = applyEvent(v, { seq: 12, method: "item/commandExecution/requestApproval", params: { requestId: "7", itemId: "c1" } });
    expect(v.requests).toHaveLength(1);
    v = applyEvent(v, { seq: 13, method: "serverRequest/resolved", params: { requestId: "7" } });
    expect(v.requests).toHaveLength(0);
  });

  test("thread/reverted drops the named turns' items", () => {
    let v = fromSnapshot(snapshot);
    v = applyEvent(v, { seq: 11, method: "item/completed", params: { turnId: "turn_2", item: { id: "a2", type: "agentMessage", text: "x" } } });
    v = applyEvent(v, { seq: 12, method: "thread/reverted", params: { threadId: "thr_1", turnIds: ["turn_2"] } });
    expect(v.items.map((i) => i.id)).toEqual(["u1", "a1"]);
  });
});

describe("plan", () => {
  test("the snapshot carries the turn's plan and turn/plan/updated replaces it", () => {
    const v = fromSnapshot({ ...snapshot, plan: { turnId: "turn_1", explanation: null, plan: [{ step: "a", status: "completed" }] } });
    expect(v.plan).toEqual({ turnId: "turn_1", explanation: null, plan: [{ step: "a", status: "completed" }] });
    const v2 = applyEvent(v, {
      seq: 11,
      method: "turn/plan/updated",
      params: { turnId: "turn_2", explanation: "next", plan: [{ step: "b", status: "inProgress" }, { step: "c", status: "pending" }] },
    });
    expect(v2.plan).toEqual({ turnId: "turn_2", explanation: "next", plan: [{ step: "b", status: "inProgress" }, { step: "c", status: "pending" }] });
    // a snapshot without a plan (older server, empty thread) is fine
    expect(fromSnapshot(snapshot).plan).toBeNull();
  });
});

describe("automatic approval review", () => {
  const action = { type: "command", source: "unifiedExec", command: "zsh -lc 'touch ~/x'", cwd: "/p" };

  test("started / completed make one item keyed by the review id; userApproved marks it (like the Store)", () => {
    let v = fromSnapshot(snapshot);
    v = applyEvent(v, {
      seq: 11,
      method: "item/autoApprovalReview/started",
      params: { threadId: "thr_1", turnId: "turn_2", reviewId: "rev-1", targetItemId: "c1", action, review: { status: "inProgress", rationale: null }, startedAtMs: 10 },
    });
    expect(v.items.at(-1)).toMatchObject({ id: "rev-1", type: "autoApprovalReview", turnId: "turn_2", targetItemId: "c1", action, review: { status: "inProgress" } });

    v = applyEvent(v, {
      seq: 12,
      method: "item/autoApprovalReview/completed",
      params: { threadId: "thr_1", turnId: "turn_2", reviewId: "rev-1", targetItemId: "c1", action, review: { status: "denied", riskLevel: "high", rationale: "exfil" }, decisionSource: "agent", startedAtMs: 10, completedAtMs: 20 },
    });
    expect(v.items.filter((i) => i.type === "autoApprovalReview")).toHaveLength(1);
    expect(v.items.at(-1)).toMatchObject({ id: "rev-1", review: { status: "denied", riskLevel: "high" }, completedAtMs: 20 });

    v = applyEvent(v, { seq: 13, method: "item/autoApprovalReview/userApproved", params: { threadId: "thr_1", reviewId: "rev-1" } });
    expect(v.items.at(-1)).toMatchObject({ id: "rev-1", userApproved: true });
    // a mark for a review we never saw changes nothing
    expect(applyEvent(v, { seq: 14, method: "item/autoApprovalReview/userApproved", params: { reviewId: "rev-9" } }).items).toEqual(v.items);
  });
});
