import { screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, test, vi } from "vitest";
import { renderAt, setViewport } from "@/ui/test-utils";
import { _resetFrameStoreForTests } from "@/core/frame";
import { channel, rpcMock, socketMock } from "@/ui/test-mocks";

vi.mock("@/ash_rpc", async () => (await import("@/ui/test-mocks")).rpcMock());
vi.mock("@/core/socket", async () => (await import("@/ui/test-mocks")).socketMock());

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
    expect(within(sheet).getByTestId("git-tool")).toBeInTheDocument();
    expect(await within(sheet).findByText("372bb036")).toBeInTheDocument();
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

  test("new thread from the threads tool navigates into it", async () => {
    setViewport(1280);
    const user = userEvent.setup();
    const { router } = renderAt("/p/app-1");
    await waitFor(() => expect(screen.getByTestId("threads-tool")).toBeInTheDocument());
    await user.click(screen.getByRole("button", { name: /新会话/ }));
    await waitFor(() => expect(router.state.location.pathname).toBe("/p/app-1/t/t2"));
  });
});
