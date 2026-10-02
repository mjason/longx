import { screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, expect, test, vi } from "vitest";
import { chromeAliases, deleteChromeBrowser, listChromeBrowsers, setChromeAlias } from "@/core/api";
import { chromeBrowser } from "@/ui/test-mocks";
import { ok, renderAt } from "@/ui/test-utils";

vi.mock("@/core/api", async () => (await import("@/ui/test-mocks")).rpcMock());
vi.mock("@/core/socket", async () => (await import("@/ui/test-mocks")).socketMock());

beforeEach(() => {
  vi.mocked(listChromeBrowsers).mockResolvedValue(ok({ browsers: [
    chromeBrowser("device-a", { name: "同名 Chrome", connected: false, device: { platform: "mac", peerIp: "192.168.1.10" } }),
    chromeBrowser("device-b", { name: "同名 Chrome", connected: true, device: { platform: "mac", peerIp: "192.168.1.11" } }),
  ] }) as never);
  vi.mocked(chromeAliases).mockResolvedValue(ok({ aliases: [{ name: "主力机", browsers: ["device-a"] }], default: "主力机" }) as never);
  vi.mocked(setChromeAlias).mockClear();
  vi.mocked(deleteChromeBrowser).mockClear();
});

async function open() {
  renderAt("/settings/browsers");
  const section = await screen.findByTestId("chrome-aliases", undefined, { timeout: 5000 });
  await within(section).findByTestId("alias-row");
  return { section, user: userEvent.setup() };
}

test("same-name browsers show IP, device ID and the alias's actual online target", async () => {
  const { section } = await open();
  const rows = screen.getAllByTestId("browser-row");
  expect(rows[0]).toHaveTextContent("192.168.1.10");
  expect(rows[0]).toHaveTextContent("device-a");
  expect(rows[1]).toHaveTextContent("192.168.1.11");
  expect(rows[1]).toHaveTextContent("device-b");
  expect(within(section).getByTestId("alias-row")).toHaveTextContent("没有在线目标");
});

test("existing aliases require explicit editing instead of accidental overwrite", async () => {
  const { section, user } = await open();
  await user.type(within(section).getByLabelText("别名"), "主力机");
  await user.click(within(section).getByRole("checkbox", { name: /192.168.1.11/ }));
  expect(within(section).getByRole("button", { name: "保存别名" })).toBeDisabled();
  expect(section).toHaveTextContent("避免误覆盖");
  expect(setChromeAlias).not.toHaveBeenCalled();
});

test("edit loads the exact target and saves the new device without changing the alias", async () => {
  const { section, user } = await open();
  await user.click(within(section).getByRole("button", { name: "编辑" }));
  expect(within(section).getByLabelText("别名")).toHaveValue("主力机");
  expect(within(section).getByLabelText("别名")).toHaveAttribute("readonly");
  const oldTarget = within(section).getByRole("checkbox", { name: /192.168.1.10/ });
  expect(oldTarget).toBeChecked();
  await user.click(oldTarget);
  await user.click(within(section).getByRole("checkbox", { name: /192.168.1.11/ }));
  await user.click(within(section).getByRole("button", { name: "保存别名" }));
  await waitFor(() => expect(setChromeAlias).toHaveBeenCalledWith(
    expect.objectContaining({ input: { name: "主力机", browsers: ["device-b"] } }),
  ));
});

test("a paired browser is deleted only after confirmation and disappears on refresh", async () => {
  const { user } = await open();
  await user.click(within(screen.getAllByTestId("browser-row")[0]!).getByRole("button", { name: "删除" }));
  const dialog = await screen.findByRole("alertdialog");
  expect(dialog).toHaveTextContent("设备记录和别名引用");
  expect(deleteChromeBrowser).not.toHaveBeenCalled();
  await user.click(within(dialog).getByRole("button", { name: "取消" }));
  expect(deleteChromeBrowser).not.toHaveBeenCalled();
  await user.click(within(screen.getAllByTestId("browser-row")[0]!).getByRole("button", { name: "删除" }));
  vi.mocked(deleteChromeBrowser).mockImplementationOnce(async () => {
    vi.mocked(listChromeBrowsers).mockResolvedValue(ok({ browsers: [chromeBrowser("device-b")] }) as never);
    return ok({ ok: true }) as never;
  });
  await user.click(within(await screen.findByRole("alertdialog")).getByRole("button", { name: "确认删除" }));
  await waitFor(() => expect(deleteChromeBrowser).toHaveBeenCalledWith(
    expect.objectContaining({ input: { id: "device-a" } }),
  ));
  await waitFor(() => expect(screen.getAllByTestId("browser-row")).toHaveLength(1));
});

test("a revoked device still has an enabled delete button", async () => {
  vi.mocked(listChromeBrowsers).mockResolvedValue(ok({ browsers: [chromeBrowser("revoked", { status: "revoked" })] }) as never);
  await open();
  const row = screen.getByTestId("browser-row");
  expect(within(row).getByRole("button", { name: "撤销" })).toBeDisabled();
  expect(within(row).getByRole("button", { name: "删除" })).toBeEnabled();
});
