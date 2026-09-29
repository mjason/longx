import { describe, expect, test } from "vitest";
import type { RunningThread } from "@/core/projects";
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
      "a",
      now,
    );
    expect(items.map((i) => i.id)).toEqual(["b", "a", "c", "d"]);
    expect(items[0]).toMatchObject({ label: "登录 COROS", note: "跑步", hint: "等你处理", tone: "waiting" });
    expect(items[1]).toMatchObject({ label: "重写解析器", note: "数学精灵", hint: "正在写 apply_patch 的参数（13 KB） · 3 分钟", tone: "running", current: true });
    expect(items[2]).toMatchObject({ hint: "coder、researcher 工作中", tone: "running" });
    expect(items[3]).toMatchObject({ label: "~d", hint: "运行中", tone: "running" });
    expect(items[0]!.current).toBeFalsy();
    // typing the project's name or the id finds the row
    expect(items[0]!.keywords).toContain("跑步");
  });
});
