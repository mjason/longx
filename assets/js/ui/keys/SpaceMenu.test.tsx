import { act, cleanup, fireEvent, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, test, vi } from "vitest";
import { renderAt, setViewport } from "@/ui/test-utils";
import { _resetFrameStoreForTests } from "@/core/frame";
import { _resetWorkbenchForTests } from "@/core/workbench";
import { setPreference } from "@/core/keys/preference";
import { commands } from "@/core/keys/registry";
import { CLOSED } from "@/core/keys/engine";
import { updateKeysUi } from "@/ui/keys/state";
import { WHICH_KEY_DELAY_MS } from "@/ui/keys/KeysLayer";
import * as api from "@/core/api";
import { ok, thread } from "@/ui/test-mocks";

vi.mock("@/core/api", async () => (await import("@/ui/test-mocks")).rpcMock());
vi.mock("@/core/socket", async () => (await import("@/ui/test-mocks")).socketMock());

// the project of the mocks and a file tab open in its workbench
const WORKBENCH = "longx:workbench:id-1";

async function openProject(path = "/p/app-1/t/t1") {
  const user = userEvent.setup();
  renderAt(path);
  await screen.findByTestId("chat-area");
  return user;
}

describe("the space menu", () => {
  beforeEach(() => {
    localStorage.clear();
    // a dialog a test left open would hide the next test's page
    updateKeysUi({ menu: CLOSED, palette: false, help: false, recording: false });
    _resetFrameStoreForTests();
    _resetWorkbenchForTests();
    setViewport(1280);
  });

  test("space outside a text field opens it with its keys; a group shows its own; escape closes it", async () => {
    const user = await openProject();
    (document.activeElement as HTMLElement | null)?.blur();
    await user.keyboard(" ");
    const menu = await screen.findByTestId("which-key");
    // the project's commands load just after the first paint: the open panel fills in as they register
    await waitFor(() => expect(menu).toHaveTextContent("和 AI 对话"));
    for (const group of ["+对话", "+会话", "+文件", "+Git", "+工具窗口", "+项目"]) expect(menu).toHaveTextContent(group);
    // the current conversation is also a closable workspace tab
    expect(menu).toHaveTextContent("+标签");

    await user.keyboard("w");
    expect(screen.getByTestId("which-key")).toHaveTextContent("SPC w");
    expect(screen.getByTestId("which-key")).toHaveTextContent("显示 / 隐藏侧栏");
    await user.keyboard("{Escape}");
    await waitFor(() => expect(screen.queryByTestId("which-key")).not.toBeInTheDocument());
  });

  test("leader help waits for a pause, restarting the delay for a quick group key", async () => {
    await openProject();
    (document.activeElement as HTMLElement | null)?.blur();
    vi.useFakeTimers();
    try {
      fireEvent.keyDown(window, { key: " ", code: "Space" });
      expect(screen.queryByTestId("which-key")).not.toBeInTheDocument();
      act(() => vi.advanceTimersByTime(WHICH_KEY_DELAY_MS - 1));
      expect(screen.queryByTestId("which-key")).not.toBeInTheDocument();
      fireEvent.keyDown(window, { key: "w", code: "KeyW" });
      act(() => vi.advanceTimersByTime(WHICH_KEY_DELAY_MS - 1));
      expect(screen.queryByTestId("which-key")).not.toBeInTheDocument();
      act(() => vi.advanceTimersByTime(1));
      expect(screen.getByTestId("which-key")).toHaveTextContent("SPC w");
      fireEvent.keyDown(window, { key: "Escape" });
      expect(screen.queryByTestId("which-key")).not.toBeInTheDocument();
    } finally {
      vi.useRealTimers();
    }
  });

  test("quick SPC SPC runs immediately without ever mounting the help panel or a stale timer", async () => {
    await openProject();
    (document.activeElement as HTMLElement | null)?.blur();
    vi.useFakeTimers();
    try {
      fireEvent.keyDown(window, { key: " ", code: "Space" });
      expect(screen.queryByTestId("which-key")).not.toBeInTheDocument();
      fireEvent.keyDown(window, { key: " ", code: "Space" });
      expect(screen.queryByTestId("which-key")).not.toBeInTheDocument();
      act(() => vi.advanceTimersByTime(0));
      expect(document.activeElement).toBe(screen.getByRole("textbox", { name: "随心输入" }));
      act(() => vi.advanceTimersByTime(WHICH_KEY_DELAY_MS * 2));
      expect(screen.queryByTestId("which-key")).not.toBeInTheDocument();
    } finally {
      vi.useRealTimers();
    }
  });

  test("a quick SPC x does not flash help; escape cancels the pending panel", async () => {
    await openProject();
    (document.activeElement as HTMLElement | null)?.blur();
    vi.useFakeTimers();
    try {
      fireEvent.keyDown(window, { key: " ", code: "Space" });
      expect(screen.queryByTestId("which-key")).not.toBeInTheDocument();
      fireEvent.keyDown(window, { key: "x", code: "KeyX" });
      expect(screen.queryByTestId("which-key")).not.toBeInTheDocument();
      fireEvent.keyDown(window, { key: "Escape" });
      act(() => vi.advanceTimersByTime(WHICH_KEY_DELAY_MS * 2));
      expect(screen.queryByTestId("which-key")).not.toBeInTheDocument();
    } finally {
      vi.useRealTimers();
    }
  });

  test("SPC b d closes the file tab on screen, SPC b u brings it back", async () => {
    localStorage.setItem(WORKBENCH, JSON.stringify({ tabs: [{ kind: "chat" }, { kind: "file", path: "README.md" }], active: "file:README.md" }));
    const user = await openProject();
    const tabs = await screen.findByTestId("workbench-tabs");
    expect(tabs).toHaveTextContent("README.md");
    (document.activeElement as HTMLElement | null)?.blur();

    await user.keyboard(" bd");
    await waitFor(() => expect(screen.queryByTestId("workbench-tabs")).not.toBeInTheDocument());
    await user.keyboard(" bu");
    expect(await screen.findByTestId("workbench-tabs")).toHaveTextContent("README.md");
  });

  test("SPC SPC puts the cursor in the AI's input; there space is a space and escape leaves it", async () => {
    const user = await openProject();
    (document.activeElement as HTMLElement | null)?.blur();
    await user.keyboard("  ");
    const input = screen.getByRole("textbox", { name: "随心输入" });
    await waitFor(() => expect(document.activeElement).toBe(input));
    expect(screen.getByTestId("status-strip")).toHaveTextContent("Esc 离开输入框");

    await user.keyboard("a b");
    expect(input).toHaveValue("a b");
    expect(screen.queryByTestId("which-key")).not.toBeInTheDocument();

    await user.keyboard("{Escape}");
    await waitFor(() => expect(document.activeElement).not.toBe(input));
    expect(screen.getByTestId("status-strip")).toHaveTextContent("空格：快捷菜单");
    await user.keyboard(" ");
    expect(await screen.findByTestId("which-key")).toBeInTheDocument();
  });

  test("SPC ? shows every key; SPC : opens the palette, whose commands carry their keys", async () => {
    const user = await openProject();
    (document.activeElement as HTMLElement | null)?.blur();
    await user.keyboard(" ?");
    const help = await screen.findByRole("dialog", { name: "全部快捷键" });
    expect(help).toHaveTextContent("SPC b d");
    expect(help).toHaveTextContent("关闭标签");
    expect(help).toHaveTextContent("SPC a s");
    await user.keyboard("{Escape}");
    await waitFor(() => expect(screen.queryByRole("dialog", { name: "全部快捷键" })).not.toBeInTheDocument());

    (document.activeElement as HTMLElement | null)?.blur();
    await user.keyboard(" :");
    const palette = await screen.findByRole("dialog", { name: "命令面板" });
    const newChat = within(palette).getByRole("option", { name: /新会话/ });
    expect(newChat).toHaveTextContent("SPC a n");
  });

  test("turned off in 外观, space does nothing", async () => {
    setPreference("spaceMenu", false);
    const user = await openProject();
    (document.activeElement as HTMLElement | null)?.blur();
    await user.keyboard(" ");
    expect(screen.queryByTestId("which-key")).not.toBeInTheDocument();
    expect(screen.getByTestId("status-strip")).not.toHaveTextContent("快捷菜单");
  });

  test("no menu on a phone", async () => {
    setViewport(390);
    const user = await openProject();
    (document.activeElement as HTMLElement | null)?.blur();
    await user.keyboard(" ");
    expect(screen.queryByTestId("which-key")).not.toBeInTheDocument();
  });

  test("⌥↓ / ⌥↑ move between the project's conversations, from the composer too", async () => {
    vi.mocked(api.listThreads).mockResolvedValue(ok([thread(1), thread(2), thread(3)]) as never);
    const { router } = renderAt("/p/app-1/t/t1");
    const user = userEvent.setup();
    await screen.findByTestId("chat-area");
    await user.click(await screen.findByRole("textbox", { name: "随心输入" }));
    // the project's commands load just after the first paint
    await waitFor(() => expect(commands.available("thread.next")).toBe(true));
    await user.keyboard("{Alt>}{ArrowDown}{/Alt}");
    await waitFor(() => expect(router.state.location.pathname).toBe("/p/app-1/t/t2"));
    await user.keyboard("{Alt>}{ArrowUp}{/Alt}");
    await waitFor(() => expect(router.state.location.pathname).toBe("/p/app-1/t/t1"));
  });

  test("Esc Esc runs the stop: the first Esc says so in the status strip, the second stops", async () => {
    const stop = vi.fn();
    const user = await openProject();
    // after the project's own (a turn is running here, as far as the keys know)
    await waitFor(() => expect(commands.available("thread.switch")).toBe(true));
    const off = commands.register({ id: "turn.stop", run: stop, available: () => true });
    try {
      await user.click(await screen.findByRole("textbox", { name: "随心输入" }));
      await user.keyboard("{Escape}");
      expect(screen.getByTestId("status-strip")).toHaveTextContent("再按 Esc：停止这一轮");
      await user.keyboard("{Escape}");
      await waitFor(() => expect(stop).toHaveBeenCalledOnce());
    } finally {
      off();
    }
  });

  test("⌘K lists this project's conversations first, then other projects' newest; running ones marked", async () => {
    vi.mocked(api.listThreads).mockResolvedValue(ok([{ ...thread(1), title: "修登录" }, { ...thread(2), title: "写文档" }]) as never);
    vi.mocked(api.listRunningThreads).mockResolvedValue(ok({ threads: [{ ...thread(2), waiting: true, projectSlug: "app-1" }] }) as never);
    vi.mocked(api.listRecentThreads).mockResolvedValue(
      ok({ threads: [{ id: "x9", title: "别的项目的会话", preview: null, lastActivityAt: null, status: "idle", projectId: "p9", projectSlug: "other", projectName: "Other" }] }) as never,
    );
    const { router } = renderAt("/p/app-1/t/t1");
    const user = userEvent.setup();
    await screen.findByTestId("chat-area");
    await user.keyboard("{Control>}k{/Control}");
    const palette = await screen.findByRole("dialog", { name: "命令面板" });
    const here = await within(palette).findByRole("group", { name: "这个项目的会话" });
    expect(here).toHaveTextContent("修登录");
    await waitFor(() => expect(within(here).getByRole("option", { name: /写文档/ })).toHaveTextContent("等你处理"));
    const other = await within(palette).findByRole("option", { name: /别的项目的会话/ });
    expect(other).toHaveTextContent("Other");
    await user.click(other);
    await waitFor(() => expect(router.state.location.pathname).toBe("/p/other/t/x9"));
  });

  test("⌘W closes a tab only in the installed app's window; in a browser tab it is the browser's", async () => {
    localStorage.setItem(WORKBENCH, JSON.stringify({ tabs: [{ kind: "chat" }, { kind: "file", path: "README.md" }], active: "file:README.md" }));
    const user = await openProject();
    expect(await screen.findByTestId("workbench-tabs")).toHaveTextContent("README.md");
    await user.keyboard("{Control>}w{/Control}");
    expect(screen.getByTestId("workbench-tabs")).toHaveTextContent("README.md");

    document.documentElement.setAttribute("data-app-window", "");
    try {
      _resetWorkbenchForTests();
      cleanup();
      const again = await openProject();
      expect(await screen.findByTestId("workbench-tabs")).toHaveTextContent("README.md");
      await again.keyboard("{Control>}w{/Control}");
      await waitFor(() => expect(screen.queryByTestId("workbench-tabs")).not.toBeInTheDocument());
      await again.keyboard("{Control>}{Shift>}t{/Shift}{/Control}");
      expect(await screen.findByTestId("workbench-tabs")).toHaveTextContent("README.md");
    } finally {
      document.documentElement.removeAttribute("data-app-window");
    }
  });
});
