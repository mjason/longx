import { screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, test, vi } from "vitest";
import { renderAt, setViewport } from "@/ui/test-utils";
import { _resetFrameStoreForTests } from "@/core/frame";
import { channel } from "@/ui/test-mocks";

vi.mock("@/ash_rpc", async () => (await import("@/ui/test-mocks")).rpcMock());
vi.mock("@/core/socket", async () => (await import("@/ui/test-mocks")).socketMock());
import { archiveProject, clearCodexHistory, updateProject } from "@/ash_rpc";

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
    await user.click(within(form).getByRole("button", { name: "保存" }));
    await waitFor(() =>
      expect(updateProject).toHaveBeenCalledWith(
        expect.objectContaining({ identity: "id-1", input: expect.objectContaining({ sandbox: "read_only", approvalPolicy: "never", dirtyStart: "ask" }) }),
      ),
    );
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

    await user.click(screen.getByRole("button", { name: "归档项目" }));
    dialog = await screen.findByRole("dialog");
    await user.click(within(dialog).getByRole("button", { name: "确认归档" }));
    await waitFor(() => expect(archiveProject).toHaveBeenCalledWith(expect.objectContaining({ identity: "id-1" })));
    await waitFor(() => expect(router.state.location.pathname).toBe("/"));
  });
});
