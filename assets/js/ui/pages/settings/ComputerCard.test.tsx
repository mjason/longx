import { screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeAll, beforeEach, expect, test, vi } from "vitest";
import { renderAt } from "@/ui/test-utils";
import { ok } from "@/ui/test-mocks";
vi.mock("@/core/api", async () => (await import("@/ui/test-mocks")).rpcMock());
vi.mock("@/core/socket", async () => (await import("@/ui/test-mocks")).socketMock());
import { computerDevices, computerAliases, computerConfigure, computerConnect, computerDisconnect, computerSetAlias } from "@/core/api";
const connection = { phase: "disconnected", foreground: false, busy: false, toolCount: 0, permissions: null, error: null };
const device = { id: "local", name: "Local", url: "http://127.0.0.1:7797/mcp", hasToken: false, connection };
beforeAll(async () => { await import("../SettingsPage"); });
beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(computerDevices).mockResolvedValue(ok([device]));
  vi.mocked(computerAliases).mockResolvedValue(ok({ default: "local", aliases: [{ name: "local", computers: ["local"] }] }));
  vi.mocked(computerConfigure).mockResolvedValue(ok({ url: "https://computer.example/mcp", hasToken: true }));
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
    input: { id: "local", name: "Local", url: "https://computer.example/mcp", token: "user-entered-fixture-key" },
  }));
  await waitFor(() => expect(within(card).queryByLabelText("访问密钥")).toBeNull());
});
test("saved credentials enable background-only connection", async () => {
  vi.mocked(computerDevices).mockResolvedValue(ok([{ ...device, hasToken: true }]));
  const user = userEvent.setup();
  renderAt("/settings/agent");
  const card = await screen.findByTestId("computer-settings");
  await user.click(await within(card).findByRole("button", { name: "连接电脑服务" }));
  await waitFor(() => expect(computerConnect).toHaveBeenCalledWith({ input: { id: "local", foreground: false } }));
});
test("missing host permissions are shown and a connection can disconnect", async () => {
  vi.mocked(computerDevices).mockResolvedValue(ok([{ ...device, hasToken: true, connection: { phase: "ready", foreground: true, busy: false, toolCount: 20, permissions: '{"screen_recording":false}', error: null } }]));
  const user = userEvent.setup();
  renderAt("/settings/agent");
  const card = await screen.findByTestId("computer-settings");
  expect(await within(card).findByRole("alert")).toHaveTextContent("Longx Computer");
  expect(card).toHaveTextContent("20 个工具");
  await user.click(within(card).getByRole("button", { name: "断开电脑操作" }));
  await waitFor(() => expect(computerDisconnect).toHaveBeenCalled());
});

test("connected foreground can be edited but only applies on explicit reconnect", async () => {
  vi.mocked(computerDevices).mockResolvedValue(ok([{ ...device, hasToken: true, connection: { ...connection, phase: "ready" } }]));
  const user = userEvent.setup();
  renderAt("/settings/agent");
  const row = await screen.findByTestId("computer-device");
  await user.click(within(row).getByRole("checkbox", { name: /允许前台控制/ }));
  expect(computerConnect).not.toHaveBeenCalled();
  expect(computerDisconnect).not.toHaveBeenCalled();
  await user.click(within(row).getByRole("button", { name: "应用并重新连接" }));
  await waitFor(() => expect(computerDisconnect).toHaveBeenCalledWith({ input: { id: "local" } }));
  await waitFor(() => expect(computerConnect).toHaveBeenCalledWith({ input: { id: "local", foreground: true } }));
});

test("two computers render independently; alias stores selected order", async () => {
  vi.mocked(computerDevices).mockResolvedValue(ok([device, { ...device, id: "win", name: "Windows", url: "https://win.example/mcp", hasToken: true }]));
  const user = userEvent.setup();
  renderAt("/settings/agent");
  await waitFor(() => expect(screen.getAllByTestId("computer-device")).toHaveLength(2));
  const aliases = screen.getByTestId("computer-aliases");
  await user.type(within(aliases).getByLabelText("别名名称"), "qa");
  await user.click(within(aliases).getByRole("checkbox", { name: "Windows" }));
  await user.click(within(aliases).getByRole("checkbox", { name: "Local" }));
  await user.click(within(aliases).getByRole("button", { name: "保存别名" }));
  await waitFor(() => expect(computerSetAlias).toHaveBeenCalledWith({ input: { name: "qa", computers: ["win", "local"] } }));
});

test("adding a computer creates a separate endpoint with masked key", async () => {
  vi.mocked(computerDevices).mockResolvedValue(ok([{ ...device, hasToken: true }]));
  const user = userEvent.setup();
  renderAt("/settings/agent");
  const card = await screen.findByTestId("computer-settings");
  await user.click(within(card).getByRole("button", { name: "添加电脑" }));
  await user.type(within(card).getByLabelText("电脑名称"), "Linux");
  const url = within(card).getByLabelText("服务地址");
  await user.clear(url);
  await user.type(url, "https://linux.example/mcp");
  const key = within(card).getByLabelText("访问密钥");
  expect(key).toHaveAttribute("type", "password");
  await user.type(key, "another-user-entered-fixture-key");
  await user.click(within(card).getByRole("button", { name: "保存连接设置" }));
  await waitFor(() => expect(computerConfigure).toHaveBeenCalledWith({ input: {
    id: expect.any(String), name: "Linux", url: "https://linux.example/mcp", token: "another-user-entered-fixture-key",
  } }));
  expect(vi.mocked(computerConfigure).mock.calls[0]?.[0]?.input?.id).not.toBe("local");
});
