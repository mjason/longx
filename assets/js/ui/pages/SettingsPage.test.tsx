import { screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, test, vi } from "vitest";
import { renderAt, setViewport } from "@/ui/test-utils";
import { ok, rpcMock, socketMock } from "@/ui/test-mocks";

vi.mock("@/ash_rpc", async () => (await import("@/ui/test-mocks")).rpcMock());
vi.mock("@/core/socket", async () =>
  (await import("@/ui/test-mocks")).socketMock(),
);
import {
  applyPreset,
  checkModel,
  createModel,
  createProvider,
  deleteModel,
  listModels,
  makeDefaultModel,
  memoryDeleteNote,
  memoryRun,
  memorySearch,
  memorySetAutoExtract,
  memoryWriteIndex,
  probeSandbox,
  sandboxStatus,
  setGithubToken,
  setToolEnabled,
  updateSearchProvider,
  upgradeApply,
  upgradeCheck,
  upgradeStatus,
} from "@/ash_rpc";
import { model, upgradeIdle } from "@/ui/test-mocks";
import { page } from "@/core/upgrade";
import { within } from "@testing-library/react";

describe("SettingsPage", () => {
  test("phone: a list of sections, then the section", async () => {
    setViewport(390);
    const user = userEvent.setup();
    const { router } = renderAt("/settings");
    await user.click(screen.getByRole("link", { name: /外观/ }));
    await waitFor(() =>
      expect(router.state.location.pathname).toBe("/settings/appearance"),
    );
    expect(screen.getByTestId("section-appearance")).toBeInTheDocument();
  });

  test("the theme follows the system unless chosen, and the toggle cycles", async () => {
    setViewport(390);
    localStorage.clear();
    const user = userEvent.setup();
    renderAt("/");
    const toggle = await screen.findByTestId("theme-toggle");
    expect(toggle).toHaveAccessibleName("主题：跟随系统");
    await user.click(toggle);
    expect(toggle).toHaveAccessibleName("主题：深色");
    expect(document.documentElement.getAttribute("data-theme")).toBe("dark");
    await user.click(toggle);
    expect(document.documentElement.getAttribute("data-theme")).toBe("light");
  });

  beforeEach(() => {
    vi.mocked(listModels).mockResolvedValue(
      ok([
        model(1, { slug: "deepseek-flash", default: true }),
        model(2, { slug: "glm-5" }),
      ]) as never,
    );
  });

  test("models: every provider with its models and key status; a provider and a model can be added", async () => {
    setViewport(1280);
    const user = userEvent.setup();
    renderAt("/settings/models");
    const prov = await screen.findByTestId("provider-p1");
    expect(prov).toHaveTextContent("https://api.deepseek.com/v1");
    expect(within(prov).getByText("deepseek-flash")).toBeInTheDocument();
    expect(within(prov).getByText("默认")).toBeInTheDocument();
    const glm = screen.getByTestId("provider-p2");
    expect(glm).toHaveTextContent("未设置密钥");
    expect(glm).toHaveTextContent("401 Authentication Fails");

    // "add" offers the templates first; 自定义 is the full form
    await user.click(screen.getByRole("button", { name: "添加 Provider" }));
    const chooser = await screen.findByRole("dialog");
    expect(
      within(chooser).getByRole("button", { name: /GLM/ }),
    ).toBeInTheDocument();
    await user.click(within(chooser).getByRole("button", { name: /自定义/ }));
    const dialog = await screen.findByRole("dialog", { name: /添加 Provider/ });
    await user.type(within(dialog).getByLabelText("名称"), "OpenAI");
    await user.type(
      within(dialog).getByLabelText("Base URL"),
      "https://api.openai.com/v1",
    );
    await user.type(within(dialog).getByLabelText("API Key"), "sk-1");
    await user.click(within(dialog).getByRole("button", { name: "保存" }));
    await waitFor(() =>
      expect(createProvider).toHaveBeenCalledWith(
        expect.objectContaining({
          input: expect.objectContaining({
            name: "OpenAI",
            slug: "openai",
            baseUrl: "https://api.openai.com/v1",
            apiKey: "sk-1",
          }),
        }),
      ),
    );

    await user.click(within(glm).getByRole("button", { name: "添加模型" }));
    const md = await screen.findByRole("dialog");
    await user.type(within(md).getByLabelText("名称"), "GLM 5");
    await user.type(within(md).getByLabelText("模型 ID"), "glm-5-turbo");
    await user.clear(within(md).getByLabelText("上下文窗口"));
    await user.type(within(md).getByLabelText("上下文窗口"), "200000");
    // the reasoning levels the model offers, and its default among them
    await user.click(
      within(md).getByRole("button", { name: "low", pressed: false }),
    );
    await user.click(
      within(md).getByRole("button", { name: "high", pressed: false }),
    );
    await user.click(within(md).getByRole("combobox", { name: "默认档" }));
    await user.click(await screen.findByRole("option", { name: "high" }));
    await user.click(within(md).getByRole("button", { name: "保存" }));
    await waitFor(() =>
      expect(createModel).toHaveBeenCalledWith(
        expect.objectContaining({
          input: expect.objectContaining({
            name: "GLM 5",
            upstreamId: "glm-5-turbo",
            providerId: "p2",
            contextWindow: 200000,
            reasoningLevels: ["low", "high"],
            reasoningEffort: "high",
          }),
        }),
      ),
    );
  });

  test("models: a template sets a provider up in one step — key, the models to add, the default", async () => {
    setViewport(1280);
    const user = userEvent.setup();
    renderAt("/settings/models");
    await screen.findByTestId("provider-p1");
    await user.click(screen.getByRole("button", { name: "添加 Provider" }));
    await user.click(
      within(await screen.findByRole("dialog")).getByRole("button", {
        name: /OpenAI/,
      }),
    );
    const dialog = await screen.findByRole("dialog", { name: /OpenAI/ });
    // where to get a key, the recommended models pre-checked, the rest not
    expect(
      within(dialog).getByRole("link", { name: /获取 API Key/ }),
    ).toHaveAttribute("href", "https://platform.openai.com/api-keys");
    expect(
      within(dialog).getByRole("checkbox", { name: /gpt-5.6-sol/ }),
    ).toBeChecked();
    expect(
      within(dialog).getByRole("checkbox", { name: /gpt-5.5/ }),
    ).not.toBeChecked();
    expect(dialog).toHaveTextContent("272k");
    await user.click(within(dialog).getByRole("checkbox", { name: /gpt-5.5/ }));
    await user.type(within(dialog).getByLabelText("API Key"), "sk-oa");
    await user.click(
      within(dialog).getByRole("combobox", { name: "默认模型" }),
    );
    await user.click(await screen.findByRole("option", { name: /gpt-5.5/ }));
    await user.click(within(dialog).getByRole("button", { name: "添加" }));
    await waitFor(() =>
      expect(applyPreset).toHaveBeenCalledWith(
        expect.objectContaining({
          input: {
            slug: "openai",
            apiKey: "sk-oa",
            models: ["gpt-5.6-sol", "gpt-5.5"],
            makeDefault: "gpt-5.5",
          },
        }),
      ),
    );

    // an installed provider offers the template's missing models from its menu
    await user.click(
      within(screen.getByTestId("provider-p1")).getByRole("button", {
        name: "Prov 的操作",
      }),
    );
    await user.click(
      await screen.findByRole("menuitem", { name: "从模版添加模型" }),
    );
    const more = await screen.findByRole("dialog", { name: /DeepSeek/ });
    expect(
      within(more).queryByRole("checkbox", { name: /deepseek-flash/ }),
    ).not.toBeInTheDocument();
    expect(
      within(more).getByRole("checkbox", { name: /deepseek-v4-pro/ }),
    ).toBeChecked();
    expect(within(more).queryByLabelText("API Key")).not.toBeInTheDocument();
    await user.click(within(more).getByRole("button", { name: "添加" }));
    await waitFor(() =>
      expect(applyPreset).toHaveBeenLastCalledWith(
        expect.objectContaining({
          input: { slug: "deepseek", models: ["deepseek-v4-pro"] },
        }),
      ),
    );
  });

  test("models: a reasoning level the list does not know is typed and added", async () => {
    setViewport(1280);
    const user = userEvent.setup();
    renderAt("/settings/models");
    const glm = await screen.findByTestId("provider-p2");
    await user.click(within(glm).getByRole("button", { name: "添加模型" }));
    const md = await screen.findByRole("dialog");
    await user.type(within(md).getByLabelText("自定义档位"), "deep");
    await user.click(within(md).getByRole("button", { name: "添加" }));
    expect(within(md).getByRole("button", { name: "deep", pressed: true })).toBeInTheDocument();
    await user.type(within(md).getByLabelText("自定义档位"), "max2{Enter}");
    expect(within(md).getByRole("button", { name: "max2", pressed: true })).toBeInTheDocument();
  });

  test("models: check, make default, delete (with a confirm)", async () => {
    setViewport(1280);
    const user = userEvent.setup();
    renderAt("/settings/models");
    const row = await screen.findByTestId("model-m2");
    await user.click(within(row).getByRole("button", { name: "检测" }));
    await waitFor(() =>
      expect(checkModel).toHaveBeenCalledWith(
        expect.objectContaining({ input: { id: "m2" } }),
      ),
    );
    await within(row).findByText(/321 ms/);
    await user.click(within(row).getByRole("button", { name: "设为默认" }));
    await waitFor(() =>
      expect(makeDefaultModel).toHaveBeenCalledWith(
        expect.objectContaining({ identity: "m2" }),
      ),
    );
    await user.click(
      within(row).getByRole("button", { name: "Model 2 的操作" }),
    );
    await user.click(await screen.findByRole("menuitem", { name: "删除模型" }));
    await user.click(
      within(await screen.findByRole("alertdialog")).getByRole("button", {
        name: "删除",
      }),
    );
    await waitFor(() =>
      expect(deleteModel).toHaveBeenCalledWith(
        expect.objectContaining({ identity: "m2" }),
      ),
    );
  });

  test("models: the search provider's key can be set", async () => {
    setViewport(1280);
    const user = userEvent.setup();
    renderAt("/settings/models");
    const search = await screen.findByTestId("search-provider");
    expect(search).toHaveTextContent("Tavily");
    await user.type(within(search).getByLabelText("API Key"), "tvly-1");
    await user.click(within(search).getByRole("button", { name: "保存" }));
    await waitFor(() =>
      expect(updateSearchProvider).toHaveBeenCalledWith(
        expect.objectContaining({
          identity: "s1",
          input: { apiKey: "tvly-1" },
        }),
      ),
    );
  });

  test("tools: the catalogue with a switch per tool", async () => {
    setViewport(1280);
    const user = userEvent.setup();
    renderAt("/settings/tools");
    const echo = await screen.findByTestId("tool-builtin.echo");
    expect(echo).toHaveTextContent("Echoes its input back.");
    const sw = within(echo).getByRole("switch");
    expect(sw).not.toBeChecked();
    await user.click(sw);
    await waitFor(() =>
      expect(setToolEnabled).toHaveBeenCalledWith(
        expect.objectContaining({ identity: "t1", input: { enabled: true } }),
      ),
    );
    expect(
      within(screen.getByTestId("tool-builtin.browser_fetch")).getByRole(
        "switch",
      ),
    ).toBeChecked();
  });

  test("sandbox: the report, and a fresh probe on request", async () => {
    setViewport(1280);
    const user = userEvent.setup();
    renderAt("/settings/sandbox");
    await screen.findByText("可用");
    const section = screen.getByTestId("section-sandbox");
    await user.click(within(section).getByRole("button", { name: "重新检测" }));
    await waitFor(() => expect(probeSandbox).toHaveBeenCalled());
    await within(section).findByText("不可用");
    expect(section).toHaveTextContent("Permission denied");
  });

  test("sandbox: Ubuntu's AppArmor restriction is named with the profile that lifts it", async () => {
    setViewport(1280);
    vi.mocked(sandboxStatus).mockResolvedValue(
      ok({
        status: "unavailable",
        reason: "apparmor: bwrap: setting up uid map: Permission denied",
        checkedAt: "2026-09-14T00:00:00Z",
      }) as never,
    );
    renderAt("/settings/sandbox");
    await waitFor(() =>
      expect(screen.getByTestId("section-sandbox")).toHaveTextContent("AppArmor"),
    );
    expect(screen.getByTestId("section-sandbox")).toHaveTextContent("apparmor_parser -r /etc/apparmor.d/longx-bwrap");
    expect(await screen.findByTestId("sandbox-banner")).toHaveTextContent("AppArmor");
  });

  test("sandbox: no network isolation is a warning that names the way out, on the page and in the banner", async () => {
    setViewport(1280);
    vi.mocked(sandboxStatus).mockResolvedValue(
      ok({
        status: "no_net_isolation",
        reason: "network_isolation: bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted",
        checkedAt: "2026-09-14T00:00:00Z",
      }) as never,
    );
    renderAt("/settings/sandbox");
    await waitFor(() =>
      expect(screen.getByTestId("section-sandbox")).toHaveTextContent("可用，但断网隔离不可用"),
    );
    expect(screen.getByTestId("section-sandbox")).toHaveTextContent("网络访问");
    const banner = await screen.findByTestId("sandbox-banner");
    expect(banner).toHaveTextContent("断网隔离不可用");
    expect(banner).toHaveTextContent("RTM_NEWADDR");
  });

  test("memory: the index is editable, the notes are listed with their origin and can be deleted, search finds lines", async () => {
    setViewport(1280);
    const user = userEvent.setup();
    renderAt("/settings/memory");
    const section = await screen.findByTestId("section-memory");
    // the pipeline's state
    await within(section).findByText("2 条待整理");
    const auto = within(section).getByRole("switch", { name: /自动提炼/ });
    expect(auto).toBeChecked();
    await user.click(auto);
    await waitFor(() =>
      expect(memorySetAutoExtract).toHaveBeenCalledWith(
        expect.objectContaining({ input: { enabled: false } }),
      ),
    );
    await user.click(within(section).getByRole("button", { name: "现在整理" }));
    await waitFor(() => expect(memoryRun).toHaveBeenCalled());

    // the index in the editor, saved as a whole
    const editor = await within(section).findByTestId("code-editor");
    await waitFor(() =>
      expect(editor.querySelector(".cm-content")).toHaveTextContent(
        "Tabs over spaces",
      ),
    );
    await user.click(editor.querySelector(".cm-content")!);
    await user.keyboard("!");
    await user.click(
      within(section).getByRole("button", { name: "保存 MEMORY.md" }),
    );
    await waitFor(() =>
      expect(memoryWriteIndex).toHaveBeenCalledWith(
        expect.objectContaining({
          input: { text: expect.stringContaining("!") },
        }),
      ),
    );

    // the notes, with where they came from
    const note = within(section).getByTestId(
      "note-notes/2026-09-14T04-48-17Z-tabs.md",
    );
    expect(note).toHaveTextContent("数学精灵");
    expect(
      within(section).getByTestId("note-notes/2026-09-14T05-00-00Z-pnpm.md"),
    ).toHaveTextContent("自动提炼");
    await user.click(within(note).getByRole("button", { name: "删除笔记" }));
    await user.click(
      within(await screen.findByRole("alertdialog")).getByRole("button", {
        name: "删除",
      }),
    );
    await waitFor(() =>
      expect(memoryDeleteNote).toHaveBeenCalledWith(
        expect.objectContaining({
          input: { file: "notes/2026-09-14T04-48-17Z-tabs.md" },
        }),
      ),
    );

    // search over everything
    await user.type(
      within(section).getByRole("searchbox", { name: "搜索记忆" }),
      "tabs{Enter}",
    );
    await waitFor(() =>
      expect(memorySearch).toHaveBeenCalledWith(
        expect.objectContaining({ input: { query: "tabs" } }),
      ),
    );
    expect(
      await within(section).findByText(/MEMORY\.md:3/),
    ).toBeInTheDocument();
  });

  test("desktop: categories beside the content, models first", async () => {
    setViewport(1280);
    const { router } = renderAt("/settings");
    await waitFor(() =>
      expect(router.state.location.pathname).toBe("/settings/models"),
    );
    expect(
      screen.getByRole("link", { name: "模型与 Provider" }),
    ).toHaveAttribute("aria-current", "page");
    expect(screen.getByTestId("section-models")).toBeInTheDocument();
  });

  test("update: the version, a check finds a release, the token, the upgrade with its stages until the new version answers", async () => {
    setViewport(1280);
    const user = userEvent.setup();
    renderAt("/settings/update");
    const section = await screen.findByTestId("section-update");
    expect(section).toHaveTextContent("Longx 0.1.0");
    expect(section).toHaveTextContent("还没检查过");
    // nothing to upgrade to yet
    expect(
      within(section).queryByRole("button", { name: /升级/ }),
    ).not.toBeInTheDocument();

    await user.click(within(section).getByRole("button", { name: "检查更新" }));
    await waitFor(() => expect(upgradeCheck).toHaveBeenCalled());
    await waitFor(() => expect(section).toHaveTextContent("有新版本 0.2.0"));
    expect(
      within(section).getByRole("link", { name: "更新说明" }),
    ).toHaveAttribute("href", "https://github.com/mjason/longx/releases/tag/v0.2.0");

    // the token: saved, then its presence shown; blank clears it (the
    // server answers the whole status, the check result included)
    vi.mocked(setGithubToken).mockImplementation(async ({ input }) =>
      ok({ ...upgradeIdle, latest: "0.2.0", available: true, hasGithubToken: !!input?.token }) as never,
    );
    await user.type(within(section).getByLabelText("GitHub token"), "ghp_abc");
    await user.click(within(section).getByRole("button", { name: "保存 token" }));
    await waitFor(() =>
      expect(setGithubToken).toHaveBeenCalledWith(
        expect.objectContaining({ input: { token: "ghp_abc" } }),
      ),
    );
    await within(section).findByText("已设置");
    await user.click(within(section).getByRole("button", { name: "清除 token" }));
    await waitFor(() =>
      expect(setGithubToken).toHaveBeenLastCalledWith(
        expect.objectContaining({ input: { token: null } }),
      ),
    );

    // the upgrade: confirm, then the stages, then the new version comes up → reload
    const reload = vi.spyOn(page, "reload").mockImplementation(() => {});
    vi.mocked(upgradeStatus)
      .mockResolvedValueOnce(
        ok({ ...upgradeIdle, latest: "0.2.0", available: true, stage: "installing", target: "0.2.0" }) as never,
      )
      .mockResolvedValueOnce(
        ok({ ...upgradeIdle, latest: "0.2.0", available: true, stage: "restarting", target: "0.2.0" }) as never,
      )
      .mockRejectedValueOnce(new Error("Failed to fetch"))
      .mockResolvedValue(ok({ ...upgradeIdle, current: "0.2.0" }) as never);
    await user.click(
      within(section).getByRole("button", { name: "升级到 0.2.0 并重启" }),
    );
    await user.click(
      within(await screen.findByRole("alertdialog")).getByRole("button", {
        name: "升级并重启",
      }),
    );
    await waitFor(() => expect(upgradeApply).toHaveBeenCalled());
    await within(section).findByText(/正在下载/);
    await within(section).findByText(/正在安装/, undefined, { timeout: 5000 });
    await within(section).findByText(/正在重启/, undefined, { timeout: 5000 });
    await waitFor(() => expect(reload).toHaveBeenCalled(), { timeout: 8000 });
  }, 20000);

  test("update: a failed upgrade says why and can be retried; a dev checkout cannot upgrade", async () => {
    setViewport(1280);
    vi.mocked(upgradeStatus).mockReset().mockResolvedValue(
      ok({
        ...upgradeIdle,
        latest: "0.2.0",
        available: true,
        checkedAt: "2026-09-14T08:00:00Z",
        stage: "failed",
        target: "0.2.0",
        message: "sha256 校验失败",
      }) as never,
    );
    renderAt("/settings/update");
    const section = await screen.findByTestId("section-update");
    await within(section).findByText(/sha256 校验失败/);
    expect(
      within(section).getByRole("button", { name: "升级到 0.2.0 并重启" }),
    ).toBeEnabled();
  });

  test("update: a dev checkout sees the release but cannot upgrade", async () => {
    setViewport(1280);
    vi.mocked(upgradeStatus).mockReset().mockResolvedValue(
      ok({ ...upgradeIdle, installed: false, latest: "0.2.0", available: true }) as never,
    );
    renderAt("/settings/update");
    const dev = await screen.findByTestId("section-update");
    await waitFor(() => expect(dev).toHaveTextContent("不是用 install.sh 安装的"));
    expect(dev).toHaveTextContent("有新版本 0.2.0");
    expect(
      within(dev).queryByRole("button", { name: /升级到/ }),
    ).not.toBeInTheDocument();
  });
});
