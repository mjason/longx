import { screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, test, vi } from "vitest";
import { renderAt, setViewport } from "@/ui/test-utils";
import { _resetFrameStoreForTests } from "@/core/frame";
import { agentDefinitionData, agentSettingsData, channel, ok } from "@/ui/test-mocks";

vi.mock("@/ash_rpc", async () => (await import("@/ui/test-mocks")).rpcMock());
vi.mock("@/core/socket", async () => (await import("@/ui/test-mocks")).socketMock());
import { agentDefinition, archiveProject, deleteProject, deleteWatch, dryRunWatch, promoteLocal, switchWatch, updateProject } from "@/ash_rpc";

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
    // no sandbox, no approval policy, no engine: the kernel is the only one
    expect(within(form).queryByRole("radio", { name: /只读/ })).not.toBeInTheDocument();
    expect(within(form).queryByText(/内核/)).not.toBeInTheDocument();
    expect(within(form).getByRole("switch", { name: /网页搜索/ })).toBeChecked();
    await user.click(within(form).getByRole("switch", { name: /网页搜索/ }));
    // no dirty-tree policy any more: Longx never commits on the person's behalf
    expect(within(form).queryByRole("radio", { name: "先问我" })).not.toBeInTheDocument();
    await user.click(within(form).getByRole("button", { name: "保存" }));
    await waitFor(() =>
      expect(updateProject).toHaveBeenCalledWith(
        expect.objectContaining({ identity: "id-1", input: expect.objectContaining({ webSearch: false, modelId: null }) }),
      ),
    );
    expect(vi.mocked(updateProject).mock.calls[0]![0]!.input).not.toHaveProperty("dirtyStart");
  });

  test("the project shows its .longx definition and the trust switch, saved with the form", async () => {
    vi.mocked(agentDefinition).mockResolvedValue(
      ok(agentDefinitionData({ present: true, model: "deepseek-flash", effort: "low", plugs: ["Longx.Agent.Plugs.Environment", "Longx.Agent.Local.P1.Deploy"], files: [".longx/agent.exs", ".longx/plugs/deploy.exs"], errors: [".longx/plugs/bad.exs:3: syntax error"] })) as never,
    );
    try {
      const user = userEvent.setup();
      renderAt("/p/app-1/settings");
      const section = await screen.findByTestId("project-agent");
      expect(await within(section).findByText(".longx/plugs/deploy.exs")).toBeInTheDocument();
      expect(within(section).getByText(/syntax error/)).toBeInTheDocument();
      expect(within(section).getByText("Longx.Agent.Local.P1.Deploy")).toBeInTheDocument();
      await user.click(within(section).getByRole("switch", { name: /信任并加载/ }));
      await user.click(screen.getByRole("button", { name: "保存" }));
      await waitFor(() =>
        expect(updateProject).toHaveBeenCalledWith(expect.objectContaining({ input: expect.objectContaining({ trustLocalAgent: true }) })),
      );
    } finally {
      vi.mocked(agentDefinition).mockResolvedValue(ok(agentDefinitionData()) as never);
    }
  });

  test("the project lists the agents it may spawn, promotes a local file to shared, and saves kernel overrides with the form", async () => {
    vi.mocked(agentDefinition).mockResolvedValue(
      ok(agentDefinitionData({
        present: true,
        agents: [
          { name: "researcher", summary: "searches the web", layer: "project" },
          { name: "helper", summary: "helps here", layer: "local" },
        ],
        localFiles: ["agents/helper/agent.exs", "plugs/x.exs"],
        settings: { ...agentSettingsData(), maxDepth: 3 },
      })) as never,
    );
    try {
      const user = userEvent.setup();
      renderAt("/p/app-1/settings");
      const section = await screen.findByTestId("project-agent");
      const agents = await within(section).findByTestId("project-agents");
      expect(agents).toHaveTextContent("researcher");
      expect(agents).toHaveTextContent("shared");
      expect(agents).toHaveTextContent("helps here");
      expect(agents).toHaveTextContent("local");

      // a local file has a promote button; the RPC gets its relative path
      const local = within(section).getByTestId("project-local-files");
      const rows = within(local).getAllByRole("listitem");
      expect(rows[1]).toHaveTextContent("plugs/x.exs");
      await user.click(within(rows[1]!).getByRole("button", { name: "提升到 shared" }));
      await waitFor(() => expect(promoteLocal).toHaveBeenCalledWith(expect.objectContaining({ input: { id: "id-1", path: "plugs/x.exs" } })));

      // the inherited value shows as the placeholder; a typed override is saved with the form, empties as null
      const depth = within(section).getByLabelText("派出深度上限") as HTMLInputElement;
      expect(depth.placeholder).toBe("沿用 3");
      await user.type(depth, "1");
      await user.click(screen.getByRole("button", { name: "保存" }));
      await waitFor(() =>
        expect(updateProject).toHaveBeenCalledWith(
          expect.objectContaining({ input: expect.objectContaining({ agentSettings: expect.objectContaining({ maxDepth: 1, maxChildren: null, childModel: null }) }) }),
        ),
      );
    } finally {
      vi.mocked(agentDefinition).mockResolvedValue(ok(agentDefinitionData()) as never);
    }
  });

  test("the project's watches: listed with state and last run; a dry run shows what it would send; switch and delete", async () => {
    const user = userEvent.setup();
    renderAt("/p/app-1/settings");
    const card = await screen.findByTestId("project-watches");
    const rows = await within(card).findAllByTestId("watch-row");
    expect(rows).toHaveLength(2);
    expect(rows[0]).toHaveTextContent("health");
    expect(rows[0]).toHaveTextContent("已开启");
    expect(rows[0]).toHaveTextContent("health ok");
    expect(rows[1]).toHaveTextContent("nightly");
    expect(rows[1]).toHaveTextContent("无法加载");
    expect(rows[1]).toHaveTextContent("not an ISO 8601 instant");

    await user.click(within(rows[0]!).getByRole("button", { name: "试跑" }));
    const dialog = await screen.findByRole("dialog");
    expect(await within(dialog).findByText(/all quiet/)).toBeInTheDocument();
    expect(within(dialog).getByText("checked")).toBeInTheDocument();
    expect(dryRunWatch).toHaveBeenCalledWith(expect.objectContaining({ input: { id: "w-health" } }));
    await user.keyboard("{Escape}");

    await user.click(within(rows[0]!).getByRole("switch"));
    expect(switchWatch).toHaveBeenCalledWith(expect.objectContaining({ input: { id: "w-health", enabled: false } }));

    vi.spyOn(window, "confirm").mockReturnValueOnce(true);
    await user.click(within(rows[1]!).getByRole("button", { name: "删除" }));
    expect(deleteWatch).toHaveBeenCalledWith(expect.objectContaining({ input: { id: "w-nightly" } }));
  });

  test("a local watch can be promoted to shared; shared watches of an untrusted project are pointed out", async () => {
    vi.mocked(agentDefinition).mockResolvedValue(
      ok(agentDefinitionData({ present: true, trusted: false, files: [".longx/shared/watches/nightly_backup.exs", ".longx/agent.exs"] })) as never,
    );
    try {
      const user = userEvent.setup();
      renderAt("/p/app-1/settings");
      const card = await screen.findByTestId("project-watches");
      const rows = await within(card).findAllByTestId("watch-row");
      await user.click(within(rows[0]!).getByRole("button", { name: "提升到 shared" }));
      await waitFor(() => expect(promoteLocal).toHaveBeenCalledWith(expect.objectContaining({ input: { id: "id-1", path: "watches/health.exs" } })));
      // shared/watches/ has a file the trust switch keeps from running
      expect(within(card).getByTestId("shared-watches-untrusted")).toHaveTextContent("nightly_backup.exs");
    } finally {
      vi.mocked(agentDefinition).mockResolvedValue(ok(agentDefinitionData()) as never);
    }
  });

  test("deleting the project asks for its name, then removes it and leaves", async () => {
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

  test("danger zone: archiving asks first; nothing else but delete is offered", async () => {
    const user = userEvent.setup();
    const { router } = renderAt("/p/app-1/settings");
    await screen.findByTestId("project-settings");
    expect(screen.queryByRole("button", { name: /codex/ })).not.toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "归档项目" }));
    let dialog = await screen.findByRole("dialog");
    await user.click(within(dialog).getByRole("button", { name: "取消" }));
    expect(archiveProject).not.toHaveBeenCalled();
    await user.click(screen.getByRole("button", { name: "归档项目" }));
    dialog = await screen.findByRole("dialog");
    await user.click(within(dialog).getByRole("button", { name: "确认归档" }));
    await waitFor(() => expect(archiveProject).toHaveBeenCalledWith(expect.objectContaining({ identity: "id-1" })));
    await waitFor(() => expect(router.state.location.pathname).toBe("/"));
  });
});
