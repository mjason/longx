import { describe, expect, test } from "vitest";
import { emptyView } from "@/core/chat/thread";
import { subagentsOf } from "@/core/chat/messages";
import { agentSummaries } from "./AgentsPanel";

const activity = (id: string, threadId: string, kind: string) => ({
  id, type: "subAgentActivity", turnId: "turn_1",
  agentThreadId: threadId, agentPath: "/root/module-migration", kind,
});

describe("current agent summaries", () => {
  test("closed children never reappear from history, even with a cached running view", () => {
    const view = {
      ...emptyView("parent"),
      earlier: { items: 2, turns: 1, partial: 0, activities: [activity("old", "closed", "interacted")] },
      items: [activity("new", "current", "completed")],
    };
    const subviews = { closed: { ...emptyView("closed"), turn: { id: "stale", status: "inProgress" } } };
    expect(agentSummaries(view, subviews, [])).toEqual([]);
    expect(agentSummaries(view, subviews, ["current"])).toMatchObject([
      { threadId: "current", name: "module-migration", state: "done" },
    ]);
    // Membership is not erased from the transcript; archived history is still openable.
    expect([...subagentsOf(view).keys()]).toEqual(["closed", "current"]);
  });

  test("same-name members stay distinct by thread id; pending asks retain their live state", () => {
    const view = { ...emptyView("parent"), items: [
      activity("a", "one", "started"), activity("b", "two", "interacted"),
    ] };
    const subviews = { two: {
      ...emptyView("two"),
      requests: [{ id: "ask", method: "longx/action/request", params: { title: "Review this" } }],
    } };
    expect(agentSummaries(view, subviews, ["one", "two"])).toMatchObject([
      { threadId: "one", state: "working" },
      { threadId: "two", state: "waiting", label: "Review this" },
    ]);
    expect(agentSummaries(view, subviews, ["two"])).toHaveLength(1);
  });

  test("a completed live turn overrides an old interacted activity's working label", () => {
    const view = { ...emptyView("parent"), items: [activity("a", "one", "interacted")] };
    const subviews = { one: { ...emptyView("one"), turn: { id: "child_turn", status: "completed" } } };
    const [summary] = agentSummaries(view, subviews, ["one"]);
    expect(summary?.state).toBe("done");
    expect(summary?.label).not.toMatch(/工作中|Working/);
  });
});
