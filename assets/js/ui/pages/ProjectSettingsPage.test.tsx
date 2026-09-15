import { screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, test, vi } from "vitest";
import { renderAt, setViewport } from "@/ui/test-utils";
import { _resetFrameStoreForTests } from "@/core/frame";
import { channel, ok } from "@/ui/test-mocks";

vi.mock("@/ash_rpc", async () => (await import("@/ui/test-mocks")).rpcMock());
vi.mock("@/core/socket", async () => (await import("@/ui/test-mocks")).socketMock());
import { archiveProject, clearCodexHistory, clearCodexMemories, deleteProject, resetCodexHome, sandboxStatus, updateProject } from "@/ash_rpc";

describe("ProjectSettingsPage", () => {
  beforeEach(() => {
    localStorage.clear();
    _resetFrameStoreForTests();
    channel.reset();
    setViewport(1280);
  });

  test("shows the project's thread defaults and saves changes", async () => {
    const user = userEvent.setup();
    renderAt("/p/app-1/settings");
    const form = await screen.findByTestId("project-settings");
    expect(within(form).getByLabelText("名称")).toHaveValue("App 1");
    expect(within(form).getByRole("radio", { name: "可写工作区" })).toBeChecked();
    await user.click(within(form).getByRole("radio", { name: "只读" }));
    await user.click(within(form).getByRole("radio", { name: "从不询问" }));
    await user.click(within(form).getByRole("radio", { name: "先问我" }));
    await user.click(within(form).getByRole("switch", { name: /子 agent/ }));
    expect(within(form).getByRole("switch", { name: /全局记忆/ })).toBeChecked();
    await user.click(within(form).getByRole("switch", { name: /全局记忆/ }));
    // extra writable directories: one per line, blanks dropped
    const roots = within(form).getByLabelText(/沙箱额外可写目录/);
    expect(roots).toHaveValue("");
    await user.type(roots, "~/.cache\n\n/data/models  ");
    await user.click(within(form).getByRole("button", { name: "保存" }));
    await waitFor(() =>
      expect(updateProject).toHaveBeenCalledWith(
        expect.objectContaining({ identity: "id-1", input: expect.objectContaining({ sandbox: "read_only", approvalPolicy: "never", dirtyStart: "ask", multiAgent: false, globalMemory: false, writableRoots: ["~/.cache", "/data/models"] }) }),
      ),
    );
  });

  test("host paths let into the sandbox: typed, or added from the machine's presets — docker flagged as host root", async () => {
    vi.mocked(sandboxStatus).mockResolvedValue(
      ok({
        status: "ok",
        reason: null,
        bwrap: "/usr/bin/bwrap",
        gpu: true,
        presets: [
          { id: "gpu", label: "GPU", paths: ["/dev/dxg"], danger: false },
          { id: "docker", label: "Docker socket", paths: ["/var/run/docker.sock"], danger: true },
        ],
        cachePresets: [{ id: "uv", label: "uv", paths: ["~/.cache/uv"] }],
        platform: "linux",
        home: "/home/mj",
        checkedAt: "",
      }) as never,
    );
    const user = userEvent.setup();
    renderAt("/p/app-1/settings");
    const form = await screen.findByTestId("project-settings");
    const box = within(form).getByLabelText(/放进沙箱的宿主路径/);
    expect(box).toHaveValue("");
    await user.type(box, "/dev/ttyUSB*");
    await user.click(await within(form).findByRole("button", { name: /添加 GPU/ }));
    await user.click(within(form).getByRole("button", { name: /添加 GPU/ }));
    expect(within(form).getByRole("button", { name: /Docker socket/ })).toHaveTextContent("等于宿主 root");
    expect(box).toHaveValue("/dev/ttyUSB*\n/dev/dxg");
    // a tool cache found on the machine is one click into the writable directories
    await user.click(within(form).getByRole("button", { name: "添加 uv 缓存" }));
    expect(within(form).getByLabelText(/沙箱额外可写目录/)).toHaveValue("~/.cache/uv");
    expect(form).toHaveTextContent("本机的服务和 socket");
    await user.click(within(form).getByRole("button", { name: "保存" }));
    await waitFor(() =>
      expect(updateProject).toHaveBeenCalledWith(
        expect.objectContaining({ input: expect.objectContaining({ passthroughPaths: ["/dev/ttyUSB*", "/dev/dxg"], writableRoots: ["~/.cache/uv"] }) }),
      ),
    );
  });

  test("on macOS / Windows the Linux-only passthrough field is not shown", async () => {
    vi.mocked(sandboxStatus).mockResolvedValue(ok({ status: "ok", reason: null, bwrap: null, gpu: false, presets: [], cachePresets: [], platform: "darwin", home: "/Users/mj", checkedAt: "" }) as never);
    renderAt("/p/app-1/settings");
    const form = await screen.findByTestId("project-settings");
    await within(form).findByLabelText(/沙箱额外可写目录/);
    expect(within(form).queryByLabelText(/放进沙箱的宿主路径/)).not.toBeInTheDocument();
  });

  test("deleting the project asks for its name, then removes it (codex data included) and leaves", async () => {
    const user = userEvent.setup();
    const { router } = renderAt("/p/app-1/settings");
    await screen.findByTestId("project-settings");
    await user.click(screen.getByRole("button", { name: "删除项目" }));
    const dialog = await screen.findByRole("dialog");
    const confirm = within(dialog).getByRole("button", { name: "确认删除" });
    expect(confirm).toBeDisabled();
    await user.type(within(dialog).getByRole("textbox"), "App 1");
    await user.click(confirm);
    await waitFor(() => expect(deleteProject).toHaveBeenCalledWith(expect.objectContaining({ identity: "id-1", input: { confirm: true } })));
    await waitFor(() => expect(router.state.location.pathname).toBe("/"));
  });

  test("danger zone: clearing codex history and archiving ask first", async () => {
    const user = userEvent.setup();
    const { router } = renderAt("/p/app-1/settings");
    await screen.findByTestId("project-settings");
    await user.click(screen.getByRole("button", { name: "清空 codex 历史" }));
    let dialog = await screen.findByRole("dialog");
    await user.click(within(dialog).getByRole("button", { name: "取消" }));
    expect(clearCodexHistory).not.toHaveBeenCalled();
    await user.click(screen.getByRole("button", { name: "清空 codex 历史" }));
    dialog = await screen.findByRole("dialog");
    await user.click(within(dialog).getByRole("button", { name: "确认清空" }));
    await waitFor(() => expect(clearCodexHistory).toHaveBeenCalledWith(expect.objectContaining({ input: { id: "id-1" } })));

    await user.click(screen.getByRole("button", { name: "清空项目记忆" }));
    dialog = await screen.findByRole("dialog");
    await user.click(within(dialog).getByRole("button", { name: "确认清空" }));
    await waitFor(() => expect(clearCodexMemories).toHaveBeenCalledWith(expect.objectContaining({ input: { id: "id-1" } })));

    await user.click(screen.getByRole("button", { name: "重置 codex 目录" }));
    dialog = await screen.findByRole("dialog");
    await user.click(within(dialog).getByRole("button", { name: "确认重置" }));
    await waitFor(() => expect(resetCodexHome).toHaveBeenCalledWith(expect.objectContaining({ input: { id: "id-1" } })));

    await user.click(screen.getByRole("button", { name: "归档项目" }));
    dialog = await screen.findByRole("dialog");
    await user.click(within(dialog).getByRole("button", { name: "确认归档" }));
    await waitFor(() => expect(archiveProject).toHaveBeenCalledWith(expect.objectContaining({ identity: "id-1" })));
    await waitFor(() => expect(router.state.location.pathname).toBe("/"));
  });
});
