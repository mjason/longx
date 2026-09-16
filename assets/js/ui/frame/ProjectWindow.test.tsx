import { screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, test, vi } from "vitest";
import { renderAt, setViewport } from "@/ui/test-utils";
import { _resetFrameStoreForTests } from "@/core/frame";
import { channel, ok, rpcMock, socketMock } from "@/ui/test-mocks";

vi.mock("@/ash_rpc", async () => (await import("@/ui/test-mocks")).rpcMock());
vi.mock("@/core/socket", async () => (await import("@/ui/test-mocks")).socketMock());
import { codexInfo, startThread, upgradeStatus } from "@/ash_rpc";
import { upgradeIdle } from "@/ui/test-mocks";

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
    expect(screen.getByTestId("status-strip")).toHaveTextContent("codex 未启动");
  });

  test("a codex that booted with settings since changed is flagged in the status bar and explained in the process tool", async () => {
    setViewport(1280);
    vi.mocked(codexInfo).mockResolvedValue(ok({ home: "/x", exists: true, bytes: 10, files: {}, worker: { phase: "ready", active_turns: 0 }, stale: ["models"] }) as never);
    const user = userEvent.setup();
    renderAt("/p/app-1/t/t1");
    const strip = await screen.findByTestId("status-strip");
    const warning = await within(strip).findByRole("button", { name: /codex 需要重启/ });
    await user.click(warning);
    const panel = await screen.findByTestId("tool-panel");
    expect(within(panel).getByTestId("process-tool")).toHaveTextContent("模型设置改了");
    expect(within(panel).getByRole("button", { name: "重启" })).toBeEnabled();
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
