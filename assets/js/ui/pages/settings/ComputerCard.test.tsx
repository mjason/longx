import { screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeAll, beforeEach, expect, test, vi } from "vitest";
import { renderAt } from "@/ui/test-utils";
import { ok } from "@/ui/test-mocks";
vi.mock("@/core/api", async () => (await import("@/ui/test-mocks")).rpcMock());
vi.mock("@/core/socket", async () => (await import("@/ui/test-mocks")).socketMock());
import { computerSettings, computerConfigure, computerConnection, computerConnect, computerDisconnect } from "@/core/api";
beforeAll(async () => { await import("../SettingsPage"); });
beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(computerSettings).mockResolvedValue(ok({ url: "http://127.0.0.1:7797/mcp", hasToken: false }));
  vi.mocked(computerConfigure).mockResolvedValue(ok({ url: "https://computer.example/mcp", hasToken: true }));
  vi.mocked(computerConnection).mockResolvedValue(ok({ phase: "disconnected", foreground: false, busy: false, toolCount: 0, permissions: null, error: null }));
});
test("service replaces installation; key is masked and cleared after save", async () => {
  const user = userEvent.setup();
  renderAt("/settings/agent");
  const card = await screen.findByTestId("computer-settings");
  const url = await within(card).findByLabelText("服务地址");
  expect(url).toHaveValue("http://127.0.0.1:7797/mcp");
  expect(within(card).queryByRole("button", { name: "下载" })).toBeNull();
  expect(within(card).getByRole("button", { name: "连接电脑服务" })).toBeDisabled();
  const key = within(card).getByLabelText("访问密钥");
  expect(key).toHaveAttribute("type", "password");
  await user.clear(url);
  await user.type(url, "https://computer.example/mcp");
  await user.type(key, "user-entered-fixture-key");
  await user.click(within(card).getByRole("button", { name: "保存连接设置" }));
  await waitFor(() => expect(computerConfigure).toHaveBeenCalledWith({
    input: { url: "https://computer.example/mcp", token: "user-entered-fixture-key" },
  }));
  await waitFor(() => expect(key).toHaveValue(""));
});
test("saved credentials enable background-only connection", async () => {
  vi.mocked(computerSettings).mockResolvedValue(ok({ url: "http://192.0.2.1:7797/mcp", hasToken: true }));
  const user = userEvent.setup();
  renderAt("/settings/agent");
  const card = await screen.findByTestId("computer-settings");
  await user.click(await within(card).findByRole("button", { name: "连接电脑服务" }));
  expect(computerConnect).toHaveBeenCalledWith({ input: { foreground: false } });
});
test("missing host permissions are shown and a connection can disconnect", async () => {
  vi.mocked(computerConnection).mockResolvedValue(ok({ phase: "ready", foreground: true, busy: false, toolCount: 20, permissions: '{"screen_recording":false}', error: null }));
  const user = userEvent.setup();
  renderAt("/settings/agent");
  const card = await screen.findByTestId("computer-settings");
  expect(await within(card).findByRole("alert")).toHaveTextContent("Longx Computer");
  expect(card).toHaveTextContent("20 个工具");
  await user.click(within(card).getByRole("button", { name: "断开电脑操作" }));
  await waitFor(() => expect(computerDisconnect).toHaveBeenCalled());
});
