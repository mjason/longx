import { screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeAll, beforeEach, describe, expect, test, vi } from "vitest";
import { renderAt } from "@/ui/test-utils";
import { browserIdle, ok } from "@/ui/test-mocks";

vi.mock("@/core/api", async () => (await import("@/ui/test-mocks")).rpcMock());
vi.mock("@/core/socket", async () => (await import("@/ui/test-mocks")).socketMock());
import { computerInstall, computerStatus } from "@/core/api";

const idle = { ...browserIdle, version: "0.32.0", latest: "0.32.0", target: "darwin-arm64", appPath: null, downloadSize: 74_965_063 };

beforeAll(async () => { await import("../SettingsPage"); });
beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(computerStatus).mockResolvedValue(ok(idle));
});

describe("Settings → local Computer Driver", () => {
  test("appears beside obscura, explains permissions and starts a download", async () => {
    const user = userEvent.setup();
    renderAt("/settings/agent");
    const card = await screen.findByTestId("computer-settings");
    expect(await within(card).findByText(/尚未下载/)).toHaveTextContent("75 MB");
    expect(card).toHaveTextContent("辅助功能");
    expect(card).toHaveTextContent("尚未启用");
    expect(screen.getByTestId("browser-settings")).toBeInTheDocument();
    await user.click(within(card).getByRole("button", { name: "下载" }));
    await waitFor(() => expect(computerInstall).toHaveBeenCalled());
    expect(await within(card).findByText("下载中")).toBeInTheDocument();
  });

  test("a failed download has a retry", async () => {
    vi.mocked(computerStatus).mockResolvedValue(ok({ ...idle, stage: "failed", error: "checksum mismatch" }));
    renderAt("/settings/agent");
    const card = await screen.findByTestId("computer-settings");
    expect(await within(card).findByRole("alert")).toHaveTextContent("checksum mismatch");
    expect(within(card).getByRole("button", { name: "重试" })).toBeEnabled();
  });

  test("installed macOS app is shown without claiming desktop access is ready", async () => {
    vi.mocked(computerStatus).mockResolvedValue(ok({
      ...idle, stage: "installed", source: "downloaded", installedVersion: "0.32.0",
      path: "/data/cua-driver/cua-driver", appPath: "/data/cua-driver/CuaDriver.app",
    }));
    renderAt("/settings/agent");
    const card = await screen.findByTestId("computer-settings");
    expect(await within(card).findByText(/已下载：/)).toHaveTextContent("/data/cua-driver/cua-driver");
    expect(card).toHaveTextContent("/data/cua-driver/CuaDriver.app");
    expect(card).toHaveTextContent("下载不会启动应用或授予权限");
    expect(within(card).queryByRole("button", { name: "下载" })).toBeNull();
  });

  test("unsupported platforms do not offer a download", async () => {
    vi.mocked(computerStatus).mockResolvedValue(ok({ ...idle, target: null, downloadSize: null }));
    renderAt("/settings/agent");
    const card = await screen.findByTestId("computer-settings");
    expect(await within(card).findByText("这个平台没有 CUA Driver 的构建。")).toBeInTheDocument();
    expect(within(card).queryByRole("button", { name: "下载" })).toBeNull();
  });
});
