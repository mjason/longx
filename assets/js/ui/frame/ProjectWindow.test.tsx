import { act, fireEvent, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, test, vi } from "vitest";
import { renderAt, setViewport } from "@/ui/test-utils";
import { _resetFrameStoreForTests } from "@/core/frame";
import { _resetWorkbenchForTests } from "@/core/workbench";
import { commands } from "@/core/keys/registry";
import { channel, ok, session } from "@/ui/test-mocks";

vi.mock("@/core/api", async () => (await import("@/ui/test-mocks")).rpcMock());
vi.mock("@/core/socket", async () => (await import("@/ui/test-mocks")).socketMock());
import { browserStatus, dependencies, directory as directoryRpc, sendMessage, setThreadHandle, setThreadOnDuty, startThread, upgradeStatus } from "@/core/api";
import { browserIdle, dependencyReport, project, thread, upgradeIdle } from "@/ui/test-mocks";

describe("ProjectWindow", () => {
  beforeEach(() => {
    localStorage.clear();
    _resetFrameStoreForTests();
    _resetWorkbenchForTests();
  });

  test("phone: chat fills the screen, tools are a bottom toolbar opening sheets", async () => {
    setViewport(390);
    const user = userEvent.setup();
    renderAt("/p/app-1");

    await waitFor(() => expect(screen.getByTestId("chat-area")).toBeInTheDocument());
    expect(screen.queryByTestId("tool-rail")).not.toBeInTheDocument();
    const toolbar = screen.getByTestId("bottom-toolbar");
    expect(channel.join).toHaveBeenCalled();

    await user.click(within(toolbar).getByLabelText("Git"));
    const sheet = await screen.findByTestId("tool-sheet");
    await within(sheet).findByTestId("git-tool");
    // the git tool opens on the branch; the status bar keeps the short HEAD
    const strip = screen.getByTestId("status-strip");
    expect(strip).toHaveTextContent("372bb036");
    // a narrow screen scrolls the strip sideways; no item breaks into two lines
    for (const item of Array.from(strip.children)) {
      expect(item).toHaveClass("whitespace-nowrap", "shrink-0");
    }
  });

  test("the status strip counts what runs now, any project; a click opens the running-conversations picker — the ones waiting on the person first, what each does — and a pick goes to that conversation", async () => {
    setViewport(1280);
    const user = userEvent.setup();
    const { listRunningThreads } = await import("@/core/api");
    const running = (id: string, over: Record<string, unknown>) => ({
      id, kernelThreadId: `k-${id}`, title: null, preview: null, lastActivityAt: null, projectId: "id-1", projectSlug: "app-1", projectName: "App", waiting: false, progress: null, turnStartedAt: null, ...over,
    });
    vi.mocked(listRunningThreads).mockResolvedValue(
      ok({
        threads: [
          running("t1", { title: "重写解析器", progress: { kind: "toolCall", name: "apply_patch", bytes: 2048 } }),
          running("t9", { title: "登录 COROS", waiting: true, projectId: "id-2", projectSlug: "runs", projectName: "跑步" }),
        ],
        // and what ended lately, under its own heading: the way back to a finished task
        finished: [{ ...running("t5", { title: "跑回测" }), outcome: "completed", finishedAt: Math.round(Date.now() / 1000) - 120, error: null }],
      }) as never,
    );
    const { router } = renderAt("/p/app-1/t/t1");
    const chip = await screen.findByTestId("running-chip");
    expect(chip).toHaveTextContent("2 个在跑 · 1 个等你 · 1 个刚完成");

    await user.click(chip);
    const dialog = await screen.findByRole("dialog");
    expect(within(dialog).getAllByRole("group").map((g) => g.getAttribute("aria-label") ?? g.textContent?.slice(0, 3))).toHaveLength(2);
    const options = within(dialog).getAllByRole("option");
    expect(options.map((o) => o.textContent)).toEqual(["登录 COROS跑步等你处理", "当前重写解析器App正在写 apply_patch 的参数（2.0 KB）", "跑回测App完成 · 2 分钟前"]);
    await user.click(options[0]!);
    await waitFor(() => expect(router.state.location.pathname).toBe("/p/runs/t/t9"));
    vi.mocked(listRunningThreads).mockResolvedValue(ok({ threads: [] }) as never);
  });

  test("the threads tool marks every conversation at work, not only the open one: the rows' `active`, and one whose sub-agent works", async () => {
    setViewport(1280);
    const { listThreads, listRunningThreads } = await import("@/core/api");
    vi.mocked(listThreads).mockResolvedValue(ok([{ ...thread(1), status: "active" }, { ...thread(2), status: "active" }, thread(3), thread(4)]) as never);
    vi.mocked(listRunningThreads).mockResolvedValue(
      ok({ threads: [{ id: "t4", kernelThreadId: "thr_4", title: null, preview: "thread 4", lastActivityAt: null, projectId: "id-1", projectSlug: "app-1", projectName: "App", waiting: false, working: ["coder"], progress: null, turnStartedAt: null, jobActivity: { total: 1, state: "processing" } }] }) as never,
    );
    try {
      renderAt("/p/app-1/t/t1");
      const panel = await screen.findByTestId("tool-panel");
      await within(panel).findByText("thread 4");
      const marked = () =>
        Array.from(panel.querySelectorAll('[data-slot="aui_thread-list-item"]'))
          .filter((item) => item.querySelector('[data-slot="aui_thread-list-item-running"]'))
          .map((item) => item.querySelector('[data-slot="aui_thread-list-item-title"]')?.textContent?.trim());
      await waitFor(() => expect(marked()).toEqual(["thread 1", "thread 2", "thread 4"]));
      const row = within(panel).getByRole("button", { name: /thread 4/ });
      await waitFor(() => expect(row).toHaveAttribute("title", "正在处理结果"));
      expect(row.querySelector('[data-slot="aui_thread-list-item-title"]')).toHaveTextContent(/^thread 4$/);
      expect(row.querySelector('[data-slot="aui_thread-list-item-running"]')).toHaveClass("text-warning", "animate-spin");
      const ordinary = within(panel).getByRole("button", { name: /thread 1/ });
      expect(ordinary.querySelector('[data-slot="aui_thread-list-item-running"]')).toHaveClass("text-primary", "animate-spin");
    } finally {
      vi.mocked(listThreads).mockResolvedValue(ok([thread(1)]) as never);
      vi.mocked(listRunningThreads).mockResolvedValue(ok({ threads: [] }) as never);
    }
  });

  test("right-clicking a conversation opens rename, archive and delete actions without navigating", async () => {
    setViewport(1280);
    const { router } = renderAt("/p/app-1/t/t1");
    const panel = await screen.findByTestId("tool-panel");
    const row = await within(panel).findByRole("button", { name: "thread 1" });
    fireEvent.contextMenu(row, { clientX: 181, clientY: 247 });

    const menu = await screen.findByRole("menu");
    expect(within(menu).getByRole("menuitem", { name: "重命名" })).toBeInTheDocument();
    expect(within(menu).getByRole("menuitem", { name: "归档" })).toBeInTheDocument();
    expect(within(menu).getByRole("menuitem", { name: "删除" })).toBeInTheDocument();
    expect(router.state.location.pathname).toBe("/p/app-1/t/t1");
    const item = row.closest('[data-slot="aui_thread-list-item"]');
    expect(item).toHaveAttribute("data-state", "open");
    expect(item).toHaveClass("select-none");
  });

  test("the status strip follows the disk: the watcher's git and files events refetch HEAD and the dirty count", async () => {
    setViewport(1280);
    channel.reset();
    const { gitInfo } = await import("@/core/api");
    const original = vi.mocked(gitInfo).getMockImplementation()!;
    const repo = (head: string | null, changes: number) => ok({ repository: head !== null, branch: head ? "main" : null, head, clean: changes === 0, changes }) as never;
    vi.mocked(gitInfo).mockResolvedValue(repo(null, 0));
    renderAt("/p/app-1/t/t1");
    const strip = await screen.findByTestId("status-strip");
    await waitFor(() => expect(strip).toHaveTextContent("no git"));

    vi.mocked(gitInfo).mockResolvedValue(repo("c0ffee0000", 0));
    act(() => channel.deliverTo("project:id-1", "git", {}));
    await waitFor(() => expect(strip).toHaveTextContent("c0ffee00"));

    vi.mocked(gitInfo).mockResolvedValue(repo("c0ffee0000", 2));
    act(() => channel.deliverTo("project:id-1", "files", { paths: ["a.txt"] }));
    await waitFor(() => expect(strip).toHaveTextContent("·2"));
    vi.mocked(gitInfo).mockImplementation(original);
  });

  test("the status strip lists enabled scheduled watches and lets me inspect their script", async () => {
    setViewport(1280);
    const user = userEvent.setup();
    const { listWatches, readFile } = await import("@/core/api");
    const originalWatches = vi.mocked(listWatches).getMockImplementation()!;
    const originalReadFile = vi.mocked(readFile).getMockImplementation()!;
    vi.mocked(listWatches).mockResolvedValue(ok([
      {
        id: "w-health", name: "health", path: "/srv/app-1/.longx/local/watches/health.exs", layer: "local",
        kind: "cron", cron: "*/5 * * * *", at: null, enabled: true, disabledReason: null, loadError: null,
        nextDueAt: "2026-09-30T08:15:00Z", runningSince: null, lastRunAt: null, lastDurationMs: null,
        lastError: null, lastOutput: null, lastSentTo: null, runs: 0, sends: 0, webhookToken: null, state: {},
      },
      {
        id: "w-off", name: "off", path: "/srv/app-1/.longx/local/watches/off.exs", layer: "local",
        kind: "cron", cron: "*/5 * * * *", at: null, enabled: false, disabledReason: "by_person", loadError: null,
        nextDueAt: null, runningSince: null, lastRunAt: null, lastDurationMs: null,
        lastError: null, lastOutput: null, lastSentTo: null, runs: 0, sends: 0, webhookToken: null, state: {},
      },
    ]) as never);
    vi.mocked(readFile).mockResolvedValue(ok({
      path: ".longx/local/watches/health.exs",
      content: 'shell(ctx, "mix test")',
      size: 22,
      binary: false,
      truncated: false,
    }) as never);
    renderAt("/p/app-1/t/t1");

    const chip = await screen.findByTestId("scheduled-watches-chip");
    expect(chip).toHaveTextContent("定时 1");
    await user.click(chip);
    const popover = await screen.findByTestId("scheduled-watches-popover");
    expect(popover).toHaveTextContent("health");
    expect(popover).not.toHaveTextContent("off");
    await user.click(within(popover).getByText("查看将执行的脚本"));
    await within(popover).findByText('shell(ctx, "mix test")');
    expect(readFile).toHaveBeenCalledWith(expect.objectContaining({
      input: { projectId: "id-1", path: ".longx/local/watches/health.exs" },
    }));
    vi.mocked(listWatches).mockImplementation(originalWatches);
    vi.mocked(readFile).mockImplementation(originalReadFile);
  });

  test("the task chip lists this project's background jobs and opens the matching conversation", async () => {
    setViewport(1280);
    const user = userEvent.setup();
    const { projectJobs } = await import("@/core/api");
    vi.mocked(projectJobs).mockResolvedValue(ok({
      jobs: [
        { name: "release", cmd: "gh run watch 123", status: "running", exitCode: null, startedAt: new Date().toISOString(), finishedAt: null, threadId: "t2", threadTitle: "发布 v0.2.83" },
        { name: "tests", cmd: "mix test", status: "exited", exitCode: 0, startedAt: new Date().toISOString(), finishedAt: new Date().toISOString(), threadId: "t3", threadTitle: "验证测试" },
      ],
    }) as never);
    const { router } = renderAt("/p/app-1/t/t1");

    const chip = await screen.findByTestId("project-jobs-chip");
    expect(chip).toHaveTextContent("任务 1");
    await user.click(chip);

    const popover = await screen.findByTestId("project-jobs-popover");
    expect(popover).toHaveTextContent("发布 v0.2.83");
    expect(popover).toHaveTextContent("运行中");
    expect(popover).not.toHaveTextContent("验证测试");

    await user.click(within(popover).getByRole("link", { name: /发布 v0\.2\.83/ }));
    await waitFor(() => expect(router.state.location.pathname).toBe("/p/app-1/t/t2"));
    vi.mocked(projectJobs).mockResolvedValue(ok({ jobs: [] }) as never);
  });

  test("the task chip is hidden when this project has only completed jobs", async () => {
    setViewport(1280);
    const { projectJobs } = await import("@/core/api");
    vi.mocked(projectJobs).mockResolvedValue(ok({
      jobs: [
        { name: "tests", cmd: "mix test", status: "exited", exitCode: 0, startedAt: new Date().toISOString(), finishedAt: new Date().toISOString(), threadId: "t3", threadTitle: "验证测试" },
      ],
    }) as never);
    renderAt("/p/app-1/t/t1");

    await waitFor(() => expect(screen.queryByTestId("project-jobs-chip")).not.toBeInTheDocument());
    vi.mocked(projectJobs).mockResolvedValue(ok({ jobs: [] }) as never);
  });

  test("the status strip counts the server's faults of the last hour and links to the record", async () => {
    setViewport(1280);
    const { recentFaults } = await import("@/core/api");
    vi.mocked(recentFaults).mockResolvedValue(ok({ faults: [{ kind: "socket_encode", where: "thread:x", detail: "d", at: "2026-09-18T10:00:00Z" }], recent: 3 }) as never);
    renderAt("/p/app-1/t/t1");
    const strip = await screen.findByTestId("status-strip");
    const item = await within(strip).findByRole("link", { name: /服务端故障/ });
    expect(item).toHaveTextContent("3");
    expect(item).toHaveAttribute("href", "/settings/requests");
    vi.mocked(recentFaults).mockResolvedValue(ok({ faults: [], recent: 0 }) as never);
  });

  test("desktop: icon rail + docked panel, ⌘2 switches tools, the status bar is there", async () => {
    setViewport(1280);
    const user = userEvent.setup();
    renderAt("/p/app-1/t/t1");

    await waitFor(() => expect(screen.getByTestId("tool-rail")).toBeInTheDocument());
    // remembered default: the threads tool is open
    const panel = screen.getByTestId("tool-panel");
    expect(await within(panel).findByText("thread 1")).toBeInTheDocument();
    // the ThreadList element marks the open thread active
    expect(within(panel).getByText("thread 1").closest("[data-active]")).toBeInTheDocument();

    await user.keyboard("{Control>}2{/Control}");
    expect(within(screen.getByTestId("tool-panel")).getByTestId("git-tool")).toBeInTheDocument();
    await user.keyboard("{Control>}2{/Control}");
    expect(screen.queryByTestId("tool-panel")).not.toBeInTheDocument();

    expect(screen.getByTestId("status-strip")).toHaveTextContent("372bb036");
    // no process to report on: the strip is HEAD and, when there is one, an update
    expect(screen.getByTestId("status-strip")).not.toHaveTextContent("codex");
  });

  test("conversations and project settings are workspace tabs; Home and settings live at the rail bottom", async () => {
    setViewport(1280);
    const user = userEvent.setup();
    const { router } = renderAt("/p/app-1/t/t1");
    await screen.findByTestId("tool-rail");
    expect(within(screen.getByTestId("project-switcher")).getByText("App 1")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "项目设置" })).toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "项目设置" }));
    await waitFor(() => expect(router.state.location.pathname).toBe("/p/app-1/settings"));
    expect(await screen.findByTestId("project-settings")).toBeInTheDocument();
    const tabs = screen.getByTestId("workbench-tabs");
    expect(within(tabs).getByRole("tab", { name: /thread 1/i })).toBeInTheDocument();
    expect(within(tabs).getByRole("tab", { name: "项目设置" })).toHaveAttribute("aria-selected", "true");

    await user.click(screen.getByRole("link", { name: "Home" }));
    await waitFor(() => expect(router.state.location.pathname).toBe("/"));
  });

  test("opening another conversation creates a separate tab and selecting it follows its route", async () => {
    setViewport(1280);
    const user = userEvent.setup();
    const { listThreads } = await import("@/core/api");
    vi.mocked(listThreads).mockResolvedValue(ok([thread(1), thread(2)]) as never);
    try {
      const { router } = renderAt("/p/app-1/t/t1");
      const panel = await screen.findByTestId("tool-panel");
      await user.click(await within(panel).findByRole("button", { name: "thread 2" }));
      await waitFor(() => expect(router.state.location.pathname).toBe("/p/app-1/t/t2"));
      const tabs = await screen.findByTestId("workbench-tabs");
      expect(within(tabs).getByRole("tab", { name: "thread 1" })).toBeInTheDocument();
      expect(within(tabs).getByRole("tab", { name: "thread 2" })).toHaveAttribute("aria-selected", "true");
      await user.click(within(tabs).getByRole("button", { name: "thread 1" }));
      await waitFor(() => expect(router.state.location.pathname).toBe("/p/app-1/t/t1"));
    } finally {
      vi.mocked(listThreads).mockResolvedValue(ok([thread(1)]) as never);
    }
  });

  test.each([1280, 390])("opening a project restores its conversation tabs without adding a new session (%i)", async (width) => {
    setViewport(width);
    localStorage.setItem("longx:workbench:id-1", JSON.stringify({
      tabs: [{ kind: "chat", threadId: "t1", title: "thread 1" }],
      active: "chat:t1",
    }));
    const { router } = renderAt("/p/app-1");
    await waitFor(() => expect(router.state.location.pathname).toBe("/p/app-1/t/t1"));
    expect(within(screen.getByTestId("workbench-tabs")).getByRole("tab", { selected: true })).toHaveTextContent("thread 1");
    expect(startThread).not.toHaveBeenCalled();

    await act(() => router.navigate("/"));
    await act(() => router.navigate("/p/app-1"));
    await waitFor(() => expect(router.state.location.pathname).toBe("/p/app-1/t/t1"));
    expect(within(screen.getByTestId("workbench-tabs")).getAllByRole("tab")).toHaveLength(1);
  });

  test("switching projects restores each workspace, including the settings tab", async () => {
    setViewport(1280);
    const { getProject } = await import("@/core/api");
    const original = vi.mocked(getProject).getMockImplementation()!;
    vi.mocked(getProject).mockImplementation(async (args) => ok(project(args?.input?.slug === "app-1" ? 1 : 2)) as never);
    localStorage.setItem("longx:workbench:id-2", JSON.stringify({
      tabs: [{ kind: "settings" }],
      active: "settings",
    }));
    try {
      const { router } = renderAt("/p/app-1/t/t1");
      await screen.findByTestId("workbench");
      await act(() => router.navigate("/p/app-2"));
      await waitFor(() => expect(router.state.location.pathname).toBe("/p/app-2/settings"));
      await screen.findByTestId("project-settings");
      expect(within(screen.getByTestId("workbench-tabs")).getAllByRole("tab")).toHaveLength(1);
      await act(() => router.navigate("/p/app-1"));
      await waitFor(() => expect(router.state.location.pathname).toBe("/p/app-1/t/t1"));
      expect(within(screen.getByTestId("workbench-tabs")).getByRole("tab", { selected: true })).toHaveTextContent("thread 1");
    } finally {
      vi.mocked(getProject).mockImplementation(original);
    }
  });

  test("opening a project with only a file tab keeps that file, without creating a conversation tab", async () => {
    setViewport(1280);
    localStorage.setItem("longx:workbench:id-1", JSON.stringify({
      tabs: [{ kind: "file", path: "README.md" }],
      active: "file:README.md",
    }));
    const { router } = renderAt("/p/app-1");
    await screen.findByTestId("workbench");
    await waitFor(() => expect(JSON.parse(localStorage.getItem("longx:workbench:id-1")!).tabs).toEqual([
      { kind: "file", path: "README.md" },
    ]));
    expect(router.state.location.pathname).toBe("/p/app-1");
    expect(within(screen.getByTestId("workbench-tabs")).getByRole("tab", { selected: true })).toHaveTextContent("README.md");
    expect(startThread).not.toHaveBeenCalled();
  });

  test("closing the last restored settings tab opens a new conversation in the now-empty workspace", async () => {
    setViewport(1280);
    localStorage.setItem("longx:workbench:id-1", JSON.stringify({
      tabs: [{ kind: "settings" }],
      active: "settings",
    }));
    const { router } = renderAt("/p/app-1");
    await screen.findByTestId("project-settings");
    await waitFor(() => expect(commands.available("tab.close")).toBe(true));
    act(() => { commands.run("tab.close"); });
    await waitFor(() => expect(router.state.location.pathname).toBe("/p/app-1"));
    await screen.findByText("让 agent 在这个项目里干活");
    expect(startThread).not.toHaveBeenCalled();
  });

  test("right-clicking a workbench tab opens its context actions", async () => {
    setViewport(1280);
    const user = userEvent.setup();
    const { router } = renderAt("/p/app-1/t/t1");
    await screen.findByTestId("tool-rail");
    await user.click(screen.getByRole("button", { name: "项目设置" }));
    const settingsTab = await screen.findByRole("tab", { name: "项目设置" });
    fireEvent.contextMenu(settingsTab, { clientX: 83, clientY: 157 });
    const menu = await screen.findByRole("menu");
    const positioner = menu.closest<HTMLElement>("[data-radix-popper-content-wrapper]");
    expect(positioner).not.toBeNull();
    const coordinates = positioner!.style.transform.match(/translate\(([-\d.]+)px, ([-\d.]+)px\)/);
    expect(coordinates).not.toBeNull();
    expect(Math.abs(Number(coordinates![1]) - 83)).toBeLessThanOrEqual(2);
    expect(Number(coordinates![2])).toBe(157);
    await user.click(await screen.findByRole("menuitem", { name: "关闭" }));
    await waitFor(() => expect(router.state.location.pathname).toBe("/p/app-1/t/t1"));
  });

  test("the status bar keeps API copy at the bottom-right, without a redundant chat-history button", async () => {
    setViewport(390);
    renderAt("/p/app-1/t/t1");
    const strip = await screen.findByTestId("status-strip");
    expect(within(strip).queryByRole("button", { name: "聊天记录" })).not.toBeInTheDocument();
    const apiButton = within(strip).getByRole("button", { name: "复制 API 地址" });
    expect(apiButton.parentElement).toHaveClass("ml-auto");
  });

  test("chat content is constrained so its thread viewport, not the page wrapper, owns scrolling", async () => {
    setViewport(1280);
    renderAt("/p/app-1/t/t1");
    const content = await screen.findByTestId("project-content");
    expect(content).toHaveClass("flex", "flex-col", "overflow-hidden");
    expect(content).not.toHaveClass("overflow-y-auto");
    const viewport = content.querySelector<HTMLElement>('[data-slot="aui_thread-viewport"]');
    expect(viewport).toHaveClass("overflow-y-scroll");
  });

  test("missing dependencies are an amber count in the status bar, linking to the dependencies page", async () => {
    setViewport(1280);
    vi.mocked(dependencies).mockResolvedValue(ok(dependencyReport({ missing: 3, installCommand: "sudo apt install fzf bat jq" })) as never);
    try {
      const user = userEvent.setup();
      const { router } = renderAt("/p/app-1/t/t1");
      const strip = await screen.findByTestId("status-strip");
      await user.click(await within(strip).findByRole("link", { name: /缺少 3 个依赖/ }));
      await waitFor(() => expect(router.state.location.pathname).toBe("/settings/dependencies"));
    } finally {
      vi.mocked(dependencies).mockResolvedValue(ok(dependencyReport()) as never);
    }
  });

  test("a browser download in progress is a percentage in the status bar, linking to the kernel page", async () => {
    setViewport(1280);
    vi.mocked(browserStatus).mockResolvedValue(ok({ ...browserIdle, stage: "downloading", received: 7_200_000, total: 60_000_000 }) as never);
    try {
      const user = userEvent.setup();
      const { router } = renderAt("/p/app-1/t/t1");
      const strip = await screen.findByTestId("status-strip");
      await user.click(await within(strip).findByRole("link", { name: /浏览器下载中 12%/ }));
      await waitFor(() => expect(router.state.location.pathname).toBe("/settings/agent"));
    } finally {
      vi.mocked(browserStatus).mockResolvedValue(ok({ ...browserIdle, stage: "installed", path: "/x/obscura" }) as never);
    }
  });

  test("a new release is a hint in the status bar, linking to the update page", async () => {
    setViewport(1280);
    vi.mocked(upgradeStatus).mockResolvedValue(ok({ ...upgradeIdle, latest: "0.2.0", available: true }) as never);
    const user = userEvent.setup();
    const { router } = renderAt("/p/app-1/t/t1");
    const strip = await screen.findByTestId("status-strip");
    await user.click(await within(strip).findByRole("link", { name: /0\.2\.0/ }));
    await waitFor(() => expect(router.state.location.pathname).toBe("/settings/update"));
  });

  test("the Agents tool lists the project's sessions with address and state; this session can be given a handle", async () => {
    setViewport(1280);
    const user = userEvent.setup();
    renderAt("/p/app-1/t/t2");
    await user.keyboard("{Control>}3{/Control}");
    const directory = await screen.findByTestId("session-directory");
    const rows = await within(directory).findAllByTestId("session-row");
    expect(rows).toHaveLength(2);
    expect(rows[0]).toHaveTextContent("main");
    expect(rows[0]).toHaveTextContent("值班");
    expect(rows[0]).toHaveTextContent("运行中");
    expect(rows[1]).toHaveTextContent("~t2");
    expect(rows[1]).toHaveTextContent("空闲");
    // this session (t2) has no handle: the field names it
    await user.type(within(directory).getByLabelText("句柄"), "ops");
    await user.click(within(directory).getByRole("button", { name: "保存" }));
    expect(setThreadHandle).toHaveBeenCalledWith(expect.objectContaining({ input: { threadId: "t2", handle: "ops" } }));
  });

  test("every session has a duty switch: a plain conversation is off until the person flips it; a named one is always on duty", async () => {
    setViewport(1280);
    const user = userEvent.setup();
    renderAt("/p/app-1/t/t2");
    await user.keyboard("{Control>}3{/Control}");
    const directory = await screen.findByTestId("session-directory");
    const rows = await within(directory).findAllByTestId("session-row");
    const named = within(rows[0]!).getByRole("switch", { name: "值班" });
    expect(named).toBeChecked();
    expect(named).toBeDisabled();
    const plain = within(rows[1]!).getByRole("switch", { name: "值班" });
    expect(plain).not.toBeChecked();
    await user.click(plain);
    expect(setThreadOnDuty).toHaveBeenCalledWith(expect.objectContaining({ input: { threadId: "t2", onDuty: true } }));
  });

  test.each([1280, 390])("other projects show on-duty sessions with full addresses; handing off preserves the draft without sending (%i)", async (width) => {
    setViewport(width);
    const local = session(1, { projectId: "id-1", handle: "main", address: "main", onDuty: true });
    const remote = session(9, { projectId: "id-2", projectSlug: "逛论坛", address: "逛论坛:notes", handle: "notes", title: "接受数据写报告", onDuty: true });
    vi.mocked(directoryRpc).mockImplementation(async (args) =>
      ok({ sessions: args?.input?.scope === "all" ? [local, remote, session(8, { projectId: "id-2", projectSlug: "逛论坛", address: "逛论坛:~t8", title: "私人聊天" })] : [local] }) as never,
    );
    try {
      const user = userEvent.setup();
      const copy = vi.spyOn(navigator.clipboard, "writeText");
      const { router } = renderAt("/p/app-1/t/t1");
      const composer = await screen.findByRole("textbox", { name: "随心输入" });
      await user.type(composer, "把研究写成 MDX");
      await user.keyboard("{Control>}3{/Control}");
      const panel = await screen.findByTestId("session-directory");
      await user.click(within(panel).getByRole("button", { name: "其他项目" }));
      await within(panel).findByText("逛论坛:notes");
      const row = (await within(panel).findAllByTestId("session-row"))[0]!;
      expect(row).toHaveTextContent("逛论坛:notes");
      expect(within(panel).queryByText("私人聊天")).not.toBeInTheDocument();
      expect(within(row).queryByRole("switch")).not.toBeInTheDocument();
      await user.click(within(row).getByRole("button", { name: "复制完整地址" }));
      expect(copy).toHaveBeenCalledWith("逛论坛:notes");
      const search = within(panel).getByRole("textbox", { name: "搜索会话或地址" });
      await user.type(search, "不存在");
      expect(within(panel).getByText("没有匹配的会话")).toBeInTheDocument();
      await user.clear(search);
      const target = (await within(panel).findAllByTestId("session-row"))[0]!;
      await user.click(within(target).getByRole("button", { name: "交给此会话" }));
      expect((composer as HTMLTextAreaElement).value).toContain("send_message");
      expect((composer as HTMLTextAreaElement).value).toContain("逛论坛:notes");
      expect((composer as HTMLTextAreaElement).value).toContain("把研究写成 MDX");
      expect(sendMessage).not.toHaveBeenCalled();
      expect(router.state.location.pathname).toBe("/p/app-1/t/t1");
      if (width === 390) {
        expect(screen.queryByTestId("tool-sheet")).not.toBeInTheDocument();
        return;
      }
      await user.click(within(target).getByRole("button", { name: /接受数据写报告/ }));
      await waitFor(() => expect(router.state.location.pathname).toBe("/p/逛论坛/t/t9"));
    } finally {
      vi.mocked(directoryRpc).mockImplementation(async () => ok({ sessions: [session(1, { handle: "main", address: "main", title: "值班", state: "running", onDuty: true }), session(2)] }) as never);
    }
  });

  test("新会话 from the threads tool opens the new-chat page (no row until the first message)", async () => {
    setViewport(1280);
    const user = userEvent.setup();
    const { router } = renderAt("/p/app-1/t/t1");
    await waitFor(() => expect(screen.getByTestId("threads-tool")).toBeInTheDocument());
    await user.click(within(screen.getByTestId("tool-panel")).getByRole("button", { name: /新会话/ }));
    await waitFor(() => expect(router.state.location.pathname).toBe("/p/app-1"));
    await waitFor(() => expect(JSON.parse(localStorage.getItem("longx:workbench:id-1")!).active).toBe("chat"));
    await waitFor(() => expect(router.state.location.state?.newChat).not.toBe(true));
    expect(startThread).not.toHaveBeenCalled();
  });
});
