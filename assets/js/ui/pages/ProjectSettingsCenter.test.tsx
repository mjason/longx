import { screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeAll, beforeEach, expect, test, vi } from "vitest";
import { renderAt, setViewport } from "@/ui/test-utils";
import { _resetFrameStoreForTests } from "@/core/frame";
import { agentDefinitionData, channel, ok, promotionPreviewData } from "@/ui/test-mocks";
vi.mock("@/core/api", async () => (await import("@/ui/test-mocks")).rpcMock());
vi.mock("@/core/socket", async () => (await import("@/ui/test-mocks")).socketMock());
import { agentDefinition, extensionInventory, previewLocal, promoteLocal, setAgentSettings, updateProject } from "@/core/api";

beforeAll(async () => { await import("./ProjectSettingsCenter"); });
beforeEach(() => {
  localStorage.clear();
  channel.reset();
  _resetFrameStoreForTests();
  setViewport(1280);
  vi.clearAllMocks();
  vi.mocked(agentDefinition).mockResolvedValue(ok(agentDefinitionData()) as never);
  vi.mocked(extensionInventory).mockResolvedValue(ok([]) as never);
});

test("global defaults can be changed inside a project without writing project overrides", async () => {
  const user = userEvent.setup();
  const { router } = renderAt("/p/app-1/settings?section=resources");
  const local = await screen.findByTestId("project-agent");
  expect(await within(local).findByLabelText("单任务内存上限（%）")).toHaveValue(null);
  await user.click(screen.getByRole("button", { name: "全局默认" }));
  const global = await screen.findByTestId("agent-settings");
  const memory = await within(global).findByLabelText("单任务内存上限（%）");
  expect(memory).toHaveValue(75);
  await user.clear(memory);
  await user.type(memory, "60");
  await user.click(within(global).getByRole("button", { name: "保存全局默认" }));
  await waitFor(() => expect(setAgentSettings).toHaveBeenCalledWith(expect.objectContaining({
    input: expect.objectContaining({ commandMemoryLimitPercent: 60 }),
  })));
  expect(updateProject).not.toHaveBeenCalled();
  expect(router.state.location.pathname).toBe("/p/app-1/settings");
  expect(router.state.location.search).toContain("scope=global");
  expect(screen.getByTestId("workbench")).toBeInTheDocument();
});

test("switching scope with a draft asks first; keeping it preserves typed values", async () => {
  const user = userEvent.setup();
  renderAt("/p/app-1/settings?section=resources");
  const section = await screen.findByTestId("project-agent");
  const memory = await within(section).findByLabelText("单任务内存上限（%）");
  await user.type(memory, "40");
  await user.click(screen.getByRole("button", { name: "全局默认" }));
  let dialog = await screen.findByRole("dialog");
  expect(dialog).toHaveTextContent("未保存");
  await user.click(within(dialog).getByRole("button", { name: "继续编辑" }));
  expect(memory).toHaveValue(40);
  await user.click(screen.getByRole("button", { name: "全局默认" }));
  dialog = await screen.findByRole("dialog");
  await user.click(within(dialog).getByRole("button", { name: "丢弃草稿并离开" }));
  expect(await screen.findByTestId("agent-settings")).toBeInTheDocument();
  expect(updateProject).not.toHaveBeenCalled();
});

test("each project option can independently restore inheritance", async () => {
  const user = userEvent.setup();
  renderAt("/p/app-1/settings?section=resources");
  const section = await screen.findByTestId("project-agent");
  const memory = await within(section).findByLabelText("单任务内存上限（%）");
  await user.type(memory, "40");
  expect(within(section).getByText("项目覆盖")).toBeInTheDocument();
  await user.click(within(section).getByRole("button", { name: "恢复继承" }));
  expect(memory).toHaveValue(null);
  await user.click(screen.getByRole("button", { name: "保存本项目" }));
  await waitFor(() => expect(updateProject).toHaveBeenCalledWith(expect.objectContaining({
    input: { agentSettings: expect.objectContaining({ commandMemoryLimitPercent: null }) },
  })));
});

test.each([1280, 390])("project scope contains only project categories at %ipx", async (width) => {
  setViewport(width);
  renderAt("/p/app-1/settings?section=project");
  const center = await screen.findByTestId("settings-center");
  const navigation = width === 390
    ? within(center).getByRole("combobox", { name: "设置中心" })
    : within(center).getByRole("navigation", { name: "设置中心" });
  expect(navigation).toHaveTextContent("项目与会话默认");
  expect(navigation).toHaveTextContent("项目扩展");
  for (const global of ["Provider", "浏览器", "电脑与命令环境", "凭证", "外观", "快捷键", "HTTPS", "版本与更新", "运行状态与诊断"]) {
    expect(navigation).not.toHaveTextContent(global);
  }
});

test("global-only bookmarks fall back to project settings; global scope remains available", async () => {
  const user = userEvent.setup();
  renderAt("/p/app-1/settings?section=providers");
  expect(await screen.findByTestId("project-settings")).toBeInTheDocument();
  expect(screen.queryByTestId("section-providers")).not.toBeInTheDocument();
  await user.click(screen.getByRole("button", { name: "全局默认" }));
  await user.click(await screen.findByRole("link", { name: "Provider" }));
  expect(await screen.findByTestId("section-providers")).toBeInTheDocument();
  expect(screen.getByTestId("workbench")).toBeInTheDocument();
  await user.click(screen.getByRole("button", { name: /当前项目 ·/ }));
  expect(await screen.findByTestId("project-settings")).toBeInTheDocument();
});

test("project-only categories switch to a valid global category", async () => {
  const user = userEvent.setup();
  const { router } = renderAt("/p/app-1/settings?section=extensions");
  await screen.findByTestId("project-extensions");
  await user.click(screen.getByRole("button", { name: "全局默认" }));
  await waitFor(() => expect(router.state.location.search).toBe("?scope=global&section=models"));
  const nav = screen.getByRole("navigation", { name: "设置中心" });
  expect(nav).not.toHaveTextContent("项目扩展");
  expect(nav).not.toHaveTextContent("项目与会话默认");
});

test("phone uses a category selector and keeps scope visible", async () => {
  setViewport(390);
  renderAt("/p/app-1/settings?section=resources");
  expect(await screen.findByRole("combobox", { name: "设置中心" })).toBeInTheDocument();
  expect(screen.getByRole("button", { name: "全局默认" })).toBeInTheDocument();
  expect(await screen.findByTestId("project-agent")).toBeInTheDocument();
});

test("artifacts are grouped separately and have no sharing or automatic deletion buttons", async () => {
  vi.mocked(extensionInventory).mockResolvedValue(ok([
    { kind: "agents", name: "helper", path: ".longx/local/agents/helper", layer: "local", shareable: true, complete: true },
    { kind: "artifacts", name: "run-a", path: ".longx/local/artifacts/e2e/run-a", layer: "local", shareable: false, complete: true },
  ]) as never);
  const user = userEvent.setup();
  renderAt("/p/app-1/settings?section=extensions");
  const manager = await screen.findByTestId("project-extensions");
  await user.click(within(manager).getByRole("tab", { name: /本地产物/ }));
  const row = await within(manager).findByTestId("extension-row");
  expect(row).toHaveTextContent("run-a");
  expect(within(row).queryByRole("button", { name: "准备共享" })).not.toBeInTheDocument();
  expect(within(manager).queryByRole("button", { name: /删除/ })).not.toBeInTheDocument();
  await user.click(within(row).getByRole("button", { name: "查看文件" }));
  expect(await screen.findByRole("dialog")).toHaveTextContent("是否仍被任务使用无法可靠确认");
  expect(promoteLocal).not.toHaveBeenCalled();
});

test("sharing is blocked by existing shared objects before mutation", async () => {
  vi.mocked(extensionInventory).mockResolvedValue(ok([
    { kind: "plugs", name: "x.exs", path: ".longx/local/plugs/x.exs", layer: "local", shareable: true, complete: true },
  ]) as never);
  vi.mocked(previewLocal).mockResolvedValueOnce(ok(promotionPreviewData("plugs/x.exs", {
    canShare: false, conflicts: [".longx/shared/plugs/x.exs"],
  })) as never);
  const user = userEvent.setup();
  renderAt("/p/app-1/settings?section=extensions");
  const manager = await screen.findByTestId("project-extensions");
  await user.click(within(manager).getByRole("tab", { name: /插件/ }));
  await user.click(await within(manager).findByRole("button", { name: "准备共享" }));
  const dialog = await screen.findByRole("dialog");
  await waitFor(() => expect(dialog).toHaveTextContent("目标已有共享对象"));
  expect(within(dialog).getByRole("button", { name: "确认移动到 shared" })).toBeDisabled();
  expect(promoteLocal).not.toHaveBeenCalled();
});
