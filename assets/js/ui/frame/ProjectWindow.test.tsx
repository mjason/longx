import { screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, test, vi } from "vitest";
import { renderAt, setViewport } from "@/ui/test-utils";
import { _resetFrameStoreForTests } from "@/core/frame";
import { channel, ok } from "@/ui/test-mocks";

vi.mock("@/ash_rpc", async () => (await import("@/ui/test-mocks")).rpcMock());
vi.mock("@/core/socket", async () => (await import("@/ui/test-mocks")).socketMock());
import { browserStatus, dependencies, startThread, upgradeStatus } from "@/ash_rpc";
import { browserIdle, dependencyReport, upgradeIdle } from "@/ui/test-mocks";

describe("ProjectWindow", () => {
  beforeEach(() => {
    localStorage.clear();
    _resetFrameStoreForTests();
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

  test("the status strip counts the server's faults of the last hour and links to the record", async () => {
    setViewport(1280);
    const { recentFaults } = await import("@/ash_rpc");
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

    await user.keyboard("{Meta>}2{/Meta}");
    expect(within(screen.getByTestId("tool-panel")).getByTestId("git-tool")).toBeInTheDocument();
    await user.keyboard("{Meta>}2{/Meta}");
    expect(screen.queryByTestId("tool-panel")).not.toBeInTheDocument();

    expect(screen.getByTestId("status-strip")).toHaveTextContent("372bb036");
    // no process to report on: the strip is HEAD and, when there is one, an update
    expect(screen.getByTestId("status-strip")).not.toHaveTextContent("codex");
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

  test("新会话 from the threads tool opens the new-chat page (no row until the first message)", async () => {
    setViewport(1280);
    const user = userEvent.setup();
    const { router } = renderAt("/p/app-1/t/t1");
    await waitFor(() => expect(screen.getByTestId("threads-tool")).toBeInTheDocument());
    await user.click(screen.getByRole("button", { name: /新会话/ }));
    await waitFor(() => expect(router.state.location.pathname).toBe("/p/app-1"));
    expect(startThread).not.toHaveBeenCalled();
  });
});
