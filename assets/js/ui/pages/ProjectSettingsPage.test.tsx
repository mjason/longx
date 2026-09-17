import { screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, test, vi } from "vitest";
import { renderAt, setViewport } from "@/ui/test-utils";
import { _resetFrameStoreForTests } from "@/core/frame";
import { agentDefinitionData, agentSettingsData, channel, ok, project } from "@/ui/test-mocks";

vi.mock("@/ash_rpc", async () => (await import("@/ui/test-mocks")).rpcMock());
vi.mock("@/core/socket", async () => (await import("@/ui/test-mocks")).socketMock());
import { agentDefinition, archiveProject, clearCodexHistory, clearCodexMemories, deleteProject, getProject, listSkills, promoteLocal, resetCodexHome, sandboxStatus, updateProject } from "@/ash_rpc";

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
    await user.click(within(form).getByRole("radio", { name: /从不询问/ }));
    await user.click(within(form).getByRole("radio", { name: "先问我" }));
    await user.click(within(form).getByRole("switch", { name: /子 agent/ }));
    expect(within(form).getByRole("switch", { name: /自动审核/ })).toBeChecked();
    await user.click(within(form).getByRole("switch", { name: /自动审核/ }));
    // extra writable directories (under 高级): one per line, blanks dropped
    await user.click(within(form).getByRole("button", { name: /长期放开的目录和设备/ }));
    const roots = within(form).getByLabelText(/沙箱额外可写目录/);
    expect(roots).toHaveValue("");
    await user.type(roots, "~/.cache\n\n/data/models  ");
    await user.click(within(form).getByRole("button", { name: "保存" }));
    await waitFor(() =>
      expect(updateProject).toHaveBeenCalledWith(
        expect.objectContaining({ identity: "id-1", input: expect.objectContaining({ sandbox: "read_only", approvalPolicy: "never", dirtyStart: "ask", multiAgent: false, autoReview: false, writableRoots: ["~/.cache", "/data/models"] }) }),
      ),
    );
  });

  test("the engine is a project setting: the native kernel is a radio with its warning", async () => {
    const user = userEvent.setup();
    renderAt("/p/app-1/settings");
    const form = await screen.findByTestId("project-settings");
    expect(within(form).getByRole("radio", { name: /codex/ })).toBeChecked();
    await user.click(within(form).getByRole("radio", { name: /原生内核/ }));
    expect(within(form).getByText(/没有沙箱/)).toBeInTheDocument();
    await user.click(within(form).getByRole("button", { name: "保存" }));
    await waitFor(() =>
      expect(updateProject).toHaveBeenCalledWith(expect.objectContaining({ input: expect.objectContaining({ engine: "native" }) })),
    );
  });

  test("a native project shows its .longx definition and the trust switch, saved with the form", async () => {
    vi.mocked(getProject).mockResolvedValue(ok({ ...project(1), engine: "native" }) as never);
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
      expect(screen.queryByTestId("project-skills")).not.toBeInTheDocument();
      await user.click(within(section).getByRole("switch", { name: /信任并加载/ }));
      await user.click(screen.getByRole("button", { name: "保存" }));
      await waitFor(() =>
        expect(updateProject).toHaveBeenCalledWith(expect.objectContaining({ input: expect.objectContaining({ trustLocalAgent: true }) })),
      );
    } finally {
      vi.mocked(getProject).mockResolvedValue(ok(project(1)) as never);
    }
  });

  test("a native project lists the agents it may spawn, promotes a local file to shared, and saves kernel overrides with the form", async () => {
    vi.mocked(getProject).mockResolvedValue(ok({ ...project(1), engine: "native" }) as never);
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
      vi.mocked(getProject).mockResolvedValue(ok(project(1)) as never);
      vi.mocked(agentDefinition).mockResolvedValue(ok(agentDefinitionData()) as never);
    }
  });

  test("the skills codex finds for the project are listed with their paths; none is said", async () => {
    vi.mocked(listSkills).mockResolvedValue(
      ok([
        { name: "docs", description: "Write the docs", shortDescription: null, path: "/srv/app-1/.agents/skills/docs/SKILL.md", enabled: true },
        { name: "review-agent", description: "Review", shortDescription: null, path: "/data/codex_home/id-1/skills/.system/review-agent/SKILL.md", enabled: true },
        { name: "mine", description: "Mine", shortDescription: null, path: "/home/mj/.agents/skills/mine/SKILL.md", enabled: true },
        { name: "installed", description: "Installed", shortDescription: null, path: "/data/codex_home/id-1/skills/installed/SKILL.md", enabled: true },
      ]) as never,
    );
    renderAt("/p/app-1/settings");
    const skills = await screen.findByTestId("project-skills");
    await waitFor(() => expect(skills).toHaveTextContent("Write the docs"));
    const rows = within(skills).getAllByRole("listitem");
    // a project skill: its path relative to the root; codex's own and the user's are labelled, not pathed
    expect(rows[0]).toHaveTextContent("$docs");
    expect(rows[0]).toHaveTextContent(".agents/skills/docs/SKILL.md");
    expect(rows[0]).not.toHaveTextContent("/srv/app-1/");
    expect(rows[1]).toHaveTextContent("codex 内置");
    expect(rows[1]).not.toHaveTextContent("codex_home");
    expect(rows[2]).toHaveTextContent("全局");
    // installed by codex's skill-installer into this project's home
    expect(rows[3]).toHaveTextContent("本项目安装");
    vi.mocked(listSkills).mockResolvedValue(ok([]) as never);
  });

  test("the long-lived exceptions sit under 高级: writable directories, and (Linux) host paths typed by hand — no presets", async () => {
    vi.mocked(sandboxStatus).mockResolvedValue(
      ok({ status: "ok", reason: null, bwrap: "/usr/bin/bwrap", gpu: true, presets: [{ id: "gpu", label: "GPU", paths: ["/dev/dxg"], danger: false }], platform: "linux", home: "/home/mj", checkedAt: "" }) as never,
    );
    const user = userEvent.setup();
    renderAt("/p/app-1/settings");
    const form = await screen.findByTestId("project-settings");
    expect(form).toHaveTextContent("本机的 socket 文件");
    // the GPU is no setting: a machine that has one puts it in every sandbox
    expect(within(form).queryByRole("switch", { name: /GPU/ })).not.toBeInTheDocument();
    expect(within(form).queryByLabelText(/沙箱额外可写目录/)).not.toBeInTheDocument();
    await user.click(within(form).getByRole("button", { name: /长期放开的目录和设备/ }));
    const roots = within(form).getByLabelText(/沙箱额外可写目录/);
    expect(roots).toHaveValue("");
    await user.type(roots, "/data/models");
    const box = within(form).getByLabelText(/放进沙箱的宿主路径/);
    await user.type(box, "/dev/ttyUSB*");
    expect(within(form).queryByRole("button", { name: /添加 GPU/ })).not.toBeInTheDocument();
    await user.click(within(form).getByRole("button", { name: "保存" }));
    await waitFor(() =>
      expect(updateProject).toHaveBeenCalledWith(
        expect.objectContaining({ input: expect.objectContaining({ writableRoots: ["/data/models"], passthroughPaths: ["/dev/ttyUSB*"] }) }),
      ),
    );
  });

  test("on macOS / Windows the Linux-only passthrough field is not shown", async () => {
    vi.mocked(sandboxStatus).mockResolvedValue(ok({ status: "ok", reason: null, bwrap: null, gpu: false, presets: [], platform: "darwin", home: "/Users/mj", checkedAt: "" }) as never);
    const user = userEvent.setup();
    renderAt("/p/app-1/settings");
    const form = await screen.findByTestId("project-settings");
    await user.click(await within(form).findByRole("button", { name: /长期放开的目录和设备/ }));
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
