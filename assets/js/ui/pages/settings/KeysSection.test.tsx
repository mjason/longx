import { screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, test, vi } from "vitest";
import { loadOverrides } from "@/core/keys/overrides";
import { renderAt, setViewport } from "@/ui/test-utils";

vi.mock("@/core/api", async () => (await import("@/ui/test-mocks")).rpcMock());
vi.mock("@/core/socket", async () => (await import("@/ui/test-mocks")).socketMock());

const LAZY = { timeout: 5000 };

// jsdom is no Mac: mod is Ctrl
async function open() {
  const user = userEvent.setup();
  renderAt("/settings/keys");
  await screen.findByTestId("section-keys", undefined, LAZY);
  return user;
}

const row = (title: string) => screen.getByTestId(`keys-row-${title}`);

describe("快捷键: every command with its keys, this device's own", () => {
  beforeEach(() => {
    localStorage.clear();
    setViewport(1280);
  });

  test("each command lists its keys; the window says whose ⌘W is", async () => {
    await open();
    expect(row("停止这一轮")).toHaveTextContent("Esc Esc");
    expect(row("停止这一轮")).toHaveTextContent("SPC a s");
    // the app's keys are marked as such in a browser tab
    expect(within(row("关闭标签")).getByText("Ctrl+W").closest("[data-app-only]")).not.toBeNull();
    expect(screen.getByTestId("section-keys")).toHaveTextContent("浏览器标签页");
  });

  test("a new key is recorded, kept on the device, and restored away", async () => {
    const user = await open();
    await user.click(within(row("停止这一轮")).getByRole("button", { name: "添加" }));
    expect(screen.getByText("按下新的快捷键…")).toBeInTheDocument();
    await user.keyboard("{Control>}{Shift>}x{/Shift}{/Control}");
    await waitFor(() => expect(row("停止这一轮")).toHaveTextContent("Ctrl+Shift+X"));
    expect(loadOverrides()["turn.stop"]).toEqual(["SPC a s", "Escape Escape", "mod+shift+x"]);

    await user.click(within(row("停止这一轮")).getByRole("button", { name: "删除 Esc Esc" }));
    expect(row("停止这一轮")).not.toHaveTextContent("Esc Esc");

    await user.click(within(row("停止这一轮")).getByRole("button", { name: "恢复默认" }));
    expect(row("停止这一轮")).toHaveTextContent("Esc Esc");
    expect(loadOverrides()["turn.stop"]).toBeUndefined();
  });

  test("a space-menu sequence starts with space and ends with Enter", async () => {
    const user = await open();
    await user.click(within(row("继续")).getByRole("button", { name: "添加" }));
    await user.keyboard(" ax{Enter}");
    await waitFor(() => expect(row("继续")).toHaveTextContent("SPC a x"));
  });

  test("a key another command holds, or an input method's, is refused with the reason", async () => {
    const user = await open();
    await user.click(within(row("停止这一轮")).getByRole("button", { name: "添加" }));
    await user.keyboard("{Control>}k{/Control}");
    expect(await screen.findByText(/已经是「命令面板」的快捷键/)).toBeInTheDocument();
    expect(loadOverrides()["turn.stop"]).toBeUndefined();

    await user.click(within(row("停止这一轮")).getByRole("button", { name: "添加" }));
    await user.keyboard("{Control>}.{/Control}");
    expect(await screen.findByText(/输入法在用这个键/)).toBeInTheDocument();
  });

  test("Esc cancels the recording; a key a tab keeps is the app's", async () => {
    const user = await open();
    await user.click(within(row("停止这一轮")).getByRole("button", { name: "添加" }));
    await user.keyboard("{Escape}");
    expect(screen.queryByText("按下新的快捷键…")).not.toBeInTheDocument();
    expect(loadOverrides()["turn.stop"]).toBeUndefined();

    await user.click(within(row("停止这一轮")).getByRole("button", { name: "添加" }));
    await user.keyboard("{Control>}n{/Control}");
    await waitFor(() => expect(row("停止这一轮")).toHaveTextContent("Ctrl+N"));
    expect(within(row("停止这一轮")).getByText("Ctrl+N").closest("[data-app-only]")).not.toBeNull();
  });
});
