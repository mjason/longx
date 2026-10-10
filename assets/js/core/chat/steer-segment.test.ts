import { describe, expect, test } from "vitest";
import { toMessages } from "./messages";
import { applyEvent, emptyView, fromSnapshot, runningTurnId, type ThreadItem, type ThreadView } from "./thread";

// Regression for "insert now": one kernel turn may have many display replies,
// but the old replies must never own a live activity dot or stall timer.
// Use the real channel-event reducer and replay the result as a reconnect
// snapshot, rather than depending on the current component's local state.
describe("steer segment activity ownership", () => {
  const reconnect = (state: ThreadView) => fromSnapshot({
    seq: state.seq,
    thread_id: state.threadId,
    thread: state.thread,
    turn: state.turn,
    turns: state.turns,
    status: state.status,
    token_usage: state.tokenUsage,
    items: state.items,
    pending_requests: state.requests,
  });

  test("multiple inserted messages and reconnects never revive an old reply's running state", () => {
    let state = applyEvent(emptyView("thread-steer"), {
      seq: 1,
      method: "turn/started",
      params: { turn: { id: "same-turn", status: "inProgress" } },
    });
    const append = (item: ThreadItem) => {
      state = applyEvent(state, {
        seq: state.seq + 1,
        method: "item/completed",
        params: { turnId: "same-turn", item },
      }, 1000 + state.seq);
    };
    append({ id: "u0", type: "userMessage", content: [{ type: "text", text: "start" }] });
    append({ id: "a0", type: "agentMessage", text: "initial reply" });
    const sealedIds: string[] = [];

    for (let n = 1; n <= 3; n++) {
      sealedIds.push(n === 1 ? "turn:same-turn" : `turn:same-turn:${n - 1}`);
      append({ id: `u${n}`, type: "userMessage", content: [{ type: "text", text: `insert ${n}` }] });
      const beforeReply = toMessages(state);
      expect(runningTurnId(state)).toBe("same-turn");
      expect(beforeReply.at(-1)!.role).toBe("user");
      expect(beforeReply.filter(m => m.status?.type === "running")).toHaveLength(0);
      for (const id of sealedIds) {
        expect(beforeReply.find(m => m.id === id)).toMatchObject({ status: { type: "complete" } });
      }
      // Reload while the next reply has not arrived: do not resurrect an old dot.
      state = reconnect(state);
      expect(toMessages(state)).toEqual(beforeReply);

      append({ id: `a${n}`, type: "agentMessage", text: `reply after insert ${n}` });
      const replying = toMessages(state);
      expect(replying.filter(m => m.status?.type === "running").map(m => m.id)).toEqual([`turn:same-turn:${n}`]);
      expect(replying.filter(m => m.role === "assistant").map(m => m.id)).toEqual([...sealedIds, `turn:same-turn:${n}`]);
      // A reconnect with both segments present must also retain only one owner.
      state = reconnect(state);
      expect(toMessages(state)).toEqual(replying);
    }

    const items = state.items;
    state = applyEvent(state, {
      seq: state.seq + 1,
      method: "turn/completed",
      params: { turn: { id: "same-turn", status: "completed" } },
    });
    expect(runningTurnId(state)).toBeNull();
    expect(toMessages(reconnect(state)).filter(m => m.role === "assistant").map(m => m.status?.type)).toEqual(["complete", "complete", "complete", "complete"]);
    expect(state.items).toEqual(items); // display sealing never removes task output
  });
});
