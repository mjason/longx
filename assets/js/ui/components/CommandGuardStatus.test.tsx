import { act, fireEvent, render, screen } from "@testing-library/react";
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
    expect(screen.getByText("具备启动保护的条件")).toBeInTheDocument();
    expect(screen.getByText("当前已确认启用保护的任务：0")).toBeInTheDocument();
    expect(screen.getByText("尚无任务保护报告")).toBeInTheDocument();
    expect(screen.queryByText("启动时已启用")).not.toBeInTheDocument();
    expect(screen.getByTestId("guard-conclusion")).toHaveTextContent("环境检测通过，等待任务验证");
    expect(screen.getByText("startup still verifies")).not.toBeVisible();
    expect(screen.getByText("/delegated")).not.toBeVisible();
    fireEvent.click(screen.getByText("技术详情"));
    expect(screen.getByText("/delegated")).toBeVisible();
  });

  test("unavailable reason and cleanup failure are visible rather than called active", () => {
    render(<CommandGuardStatusView data={{ ...report, capability: "unavailable",
      reason: "no delegation", cleanupPendingTasks: 1, lastTaskStatus: "active",
      lastCleanupError: "blocked task", lastPopulated: true }} />);
    expect(screen.getByText("当前不可用")).toBeInTheDocument();
    expect(screen.getByText("no delegation")).not.toBeVisible();
    expect(screen.getByText("blocked task")).toBeInTheDocument();
    expect(screen.getByText(/尚未确认清理完成的任务：1/)).toBeInTheDocument();
    expect(screen.getByText("启动时已启用")).toBeInTheDocument();
    expect(screen.getByText("当前已确认启用保护的任务：0")).toBeInTheDocument();
    expect(screen.getByTestId("guard-conclusion")).toHaveTextContent("任务清理需要关注");
  });

  test("off explicitly reports that detection was not run", () => {
    render(<CommandGuardStatusView data={{ ...report, mode: "off", capability: "off", reason: null }} />);
    expect(screen.getByText("已关闭；未执行检测")).toBeInTheDocument();
  });

  test("only running task reports can claim active protection; finished reports cannot", () => {
    const { rerender } = render(<CommandGuardStatusView data={{ ...report, activeTasks: 1, lastTaskStatus: "active" }} />);
    expect(screen.getByTestId("guard-conclusion")).toHaveTextContent("有任务正在受 cgroup 保护");
    rerender(<CommandGuardStatusView data={{ ...report, activeTasks: 0, lastTaskStatus: "active", lastPopulated: false }} />);
    expect(screen.getByTestId("guard-conclusion")).toHaveTextContent("当前没有正在受保护的任务");
    expect(screen.getByText("启动时已启用")).toBeInTheDocument();
  });

  test("saved off mode does not erase an existing protected task", () => {
    render(<CommandGuardStatusView data={{ ...report, mode: "off", capability: "off", activeTasks: 1 }} />);
    expect(screen.getByTestId("guard-conclusion")).toHaveTextContent("有任务正在受 cgroup 保护");
    expect(screen.getByText("已关闭；未执行检测")).toBeInTheDocument();
  });

  test("required mode explains why new tasks cannot start and OOM remains visible", () => {
    render(<CommandGuardStatusView data={{ ...report, mode: "required", capability: "unavailable", lastOomKill: 2 }} />);
    expect(screen.getByText("必须启用模式下，无法启用保护的新任务会拒绝启动。")).toBeInTheDocument();
    expect(screen.getByText("最近任务报告了 2 次 OOM 终止（内存不足）。")).toBeVisible();
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
