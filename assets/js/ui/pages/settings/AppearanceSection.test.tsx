import { screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { getPreference } from "@/core/keys/preference";
import { renderAt, setViewport } from "@/ui/test-utils";

vi.mock("@/core/api", async () => (await import("@/ui/test-mocks")).rpcMock());
vi.mock("@/core/socket", async () => (await import("@/ui/test-mocks")).socketMock());

const LAZY = { timeout: 5000 };

class FakeNotification {
  static permission: NotificationPermission = "default";
  static answer: NotificationPermission = "granted";
  static requestPermission = vi.fn(async () => {
    FakeNotification.permission = FakeNotification.answer;
    return FakeNotification.answer;
  });
}

beforeEach(() => {
  localStorage.clear();
  setViewport(1280);
  FakeNotification.permission = "default";
});

afterEach(() => {
  vi.unstubAllGlobals();
  Object.defineProperty(window, "isSecureContext", { configurable: true, value: false });
});

describe("外观: this device's choices", () => {
  test("the space menu and the reasoning's default are switches kept on this device", async () => {
    const user = userEvent.setup();
    renderAt("/settings/appearance");
    const spaceMenu = await screen.findByRole("switch", { name: "空格快捷菜单" }, LAZY);
    expect(spaceMenu).toBeChecked();
    await user.click(spaceMenu);
    expect(getPreference("spaceMenu")).toBe(false);

    const reasoning = screen.getByRole("switch", { name: "思考过程默认展开" });
    expect(reasoning).not.toBeChecked();
    await user.click(reasoning);
    expect(getPreference("reasoningOpen")).toBe(true);
  });

  test("over plain http, notifications and the offline cache are off and say HTTPS is needed", async () => {
    Object.defineProperty(window, "isSecureContext", { configurable: true, value: false });
    renderAt("/settings/appearance");
    expect(await screen.findByRole("switch", { name: "系统通知" }, LAZY)).toBeDisabled();
    expect(screen.getByRole("switch", { name: "离线缓存" })).toBeDisabled();
    expect(screen.getByText(/系统通知需要 HTTPS/)).toBeInTheDocument();
    expect(screen.getByText(/离线缓存需要 HTTPS/)).toBeInTheDocument();
  });

  test("turning notifications on asks the browser; a refusal leaves them off and says where to allow them", async () => {
    Object.defineProperty(window, "isSecureContext", { configurable: true, value: true });
    vi.stubGlobal("Notification", FakeNotification);
    const user = userEvent.setup();
    renderAt("/settings/appearance");
    const notifications = await screen.findByRole("switch", { name: "系统通知" }, LAZY);
    expect(notifications).not.toBeChecked();

    FakeNotification.answer = "denied";
    await user.click(notifications);
    await waitFor(() => expect(FakeNotification.requestPermission).toHaveBeenCalled());
    expect(await screen.findByText(/浏览器拒绝了通知权限/)).toBeInTheDocument();
    expect(getPreference("notifications")).toBe(false);
    expect(notifications).not.toBeChecked();
  });

  test("granted: on, and off again without asking", async () => {
    Object.defineProperty(window, "isSecureContext", { configurable: true, value: true });
    vi.stubGlobal("Notification", FakeNotification);
    FakeNotification.answer = "granted";
    const user = userEvent.setup();
    renderAt("/settings/appearance");
    const notifications = await screen.findByRole("switch", { name: "系统通知" }, LAZY);
    await user.click(notifications);
    await waitFor(() => expect(notifications).toBeChecked());
    expect(getPreference("notifications")).toBe(true);
    await user.click(notifications);
    expect(getPreference("notifications")).toBe(false);
  });
});
