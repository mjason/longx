import { describe, expect, test } from "vitest";
import type { FinishedThread, RunningThread } from "@/core/projects";
import { runningItems } from "./runningPicker";

const thread = (over: Partial<RunningThread>): RunningThread => ({
  id: "t1",
  kernelThreadId: "k1",
  title: null,
  preview: null,
  lastActivityAt: null,
  projectId: "p1",
  projectSlug: "math",
  projectName: "数学精灵",
  waiting: false,
  progress: null,
  turnStartedAt: null,
  ...over,
});

describe("the running-threads picker", () => {
  test("rows: the ones waiting on the person first, each with its project, what it is doing and for how long; the conversation on screen marked", () => {
    const now = 1_000_000 * 1000;
    const items = runningItems(
      [
        thread({ id: "a", title: "重写解析器", progress: { kind: "toolCall", name: "apply_patch", bytes: 13 * 1024 }, turnStartedAt: 1_000_000 - 200 }),
        thread({ id: "b", preview: "登录 COROS", waiting: true, projectSlug: "runs", projectName: "跑步" }),
        thread({ id: "c", title: "派 coder 去", working: ["coder", "researcher"] }),
        thread({ id: "d" }),
      ],
      [],
      "a",
      now,
    );
    expect(items.map((i) => i.id)).toEqual(["b", "a", "c", "d"]);
    expect(items.every((i) => i.group === "在跑")).toBe(true);
    expect(items[0]).toMatchObject({ label: "登录 COROS", note: "跑步", hint: "等你处理", tone: "waiting" });
    expect(items[1]).toMatchObject({ label: "重写解析器", note: "数学精灵", hint: "正在写 apply_patch 的参数（13 KB） · 3 分钟", tone: "running", current: true });
    expect(items[2]).toMatchObject({ hint: "coder、researcher 工作中", tone: "running" });
    expect(items[3]).toMatchObject({ label: "~d", hint: "运行中", tone: "running" });
    expect(items[0]!.current).toBeFalsy();
    // typing the project's name or the id finds the row
    expect(items[0]!.keywords).toContain("跑步");
  });

  test("what finished lately follows, under its own heading: how the turn ended and when", () => {
    const now = 1_000_000 * 1000;
    const done: FinishedThread = { id: "f", kernelThreadId: "kf", title: "跑回测", preview: null, lastActivityAt: null, projectId: "p1", projectSlug: "math", projectName: "数学精灵", outcome: "completed", finishedAt: 1_000_000 - 300, error: null };
    const failed: FinishedThread = { ...done, id: "g", title: "升级框架", outcome: "failed", error: "boom" };
    const items = runningItems([thread({ id: "a", title: "在跑的" })], [done, failed], "f", now);
    expect(items.map((i) => [i.id, i.group])).toEqual([
      ["a", "在跑"],
      ["f", "刚完成"],
      ["g", "刚完成"],
    ]);
    expect(items[1]).toMatchObject({ label: "跑回测", note: "数学精灵", hint: "完成 · 5 分钟前", tone: "finished", current: true });
    expect(items[2]).toMatchObject({ hint: "失败 · 5 分钟前" });
  });
});
