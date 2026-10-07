import { act, render, screen } from "@testing-library/react";
import { describe, expect, test } from "vitest";
import { CommandGuardStatusView } from "./CommandGuardStatus";
import type { CommandGuardStatus } from "@/core/agent";
import i18n from "@/core/i18n";

const report: CommandGuardStatus = {
  mode: "auto", platform: "linux", capability: "eligible", reason: "startup still verifies",
  path: "/delegated", activeTasks: 0, cleanupPendingTasks: 0, lastTaskStatus: null,
  lastTaskReason: null, lastTaskPath: null, lastOomKill: null, lastPopulated: null,
  lastCleanupError: null, lastObservedAt: null, checkedAt: "2026-10-07T00:00:00Z",
};

describe("CommandGuardStatus", () => {
  test("eligible only means preflight; it does not claim active task protection", () => {
    render(<CommandGuardStatusView data={report} />);
    expect(screen.getByText("前置检测满足条件；待真实任务启动确认")).toBeInTheDocument();
    expect(screen.getByText("当前已确认启用保护的任务：0")).toBeInTheDocument();
    expect(screen.getByText("尚无任务保护报告")).toBeInTheDocument();
    expect(screen.queryByText("启动时已启用")).not.toBeInTheDocument();
  });

  test("unavailable reason and cleanup failure are visible rather than called active", () => {
    render(<CommandGuardStatusView data={{ ...report, capability: "unavailable",
      reason: "no delegation", cleanupPendingTasks: 1, lastTaskStatus: "active",
      lastCleanupError: "blocked task", lastPopulated: true }} />);
    expect(screen.getByText("当前不可用")).toBeInTheDocument();
    expect(screen.getByText("no delegation")).toBeInTheDocument();
    expect(screen.getByText("blocked task")).toBeInTheDocument();
    expect(screen.getByText(/尚未确认清理完成的任务：1/)).toBeInTheDocument();
    expect(screen.getByText("启动时已启用")).toBeInTheDocument();
    expect(screen.getByText("当前已确认启用保护的任务：0")).toBeInTheDocument();
  });

  test("off explicitly reports that detection was not run", () => {
    render(<CommandGuardStatusView data={{ ...report, mode: "off", capability: "off", reason: null }} />);
    expect(screen.getByText("已关闭；未执行检测")).toBeInTheDocument();
  });

  test("status copy follows language changes, including counts and unsupported platforms", async () => {
    render(<CommandGuardStatusView data={{ ...report, capability: "unsupported" }} />);
    expect(screen.getByText("当前平台不支持 Linux cgroup")).toBeInTheDocument();
    try {
      await act(() => i18n.changeLanguage("en"));
      expect(screen.getByText("This platform does not support Linux cgroups")).toBeInTheDocument();
      expect(screen.getByText("Tasks with confirmed active protection: 0")).toBeInTheDocument();
      expect(screen.getByText("Saved mode: Auto · linux")).toBeInTheDocument();
    } finally {
      await act(() => i18n.changeLanguage("zh-CN"));
    }
  });
});
