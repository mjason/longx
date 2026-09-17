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
  agentDeleteFile,
  agentWriteFile,
  setAgentSettings,
  knowledgeDelete,
  knowledgeWrite,
  setBrowserPrivateNetwork,
  applyPreset,
  checkModel,
  createModel,
  createProvider,
  deleteModel,
  discoverModels,
  listCodexProcesses,
  listModels,
  makeDefaultModel,
  memoryDeleteNote,
  memoryRun,
  memorySearch,
  memorySetAutoExtract,
  memoryWriteIndex,
  probeSandbox,
  reviewSettings,
  sandboxStatus,
  setGithubToken,
  setReviewModel,
  setToolEnabled,
  stopCodex,
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
        model(2, { slug: "glm-5", reasoningLevels: ["low", "high"] }),
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
    // any whole number: a vendor's window need not be a round thousand (Bailian's qwen3.8 is 983616)
    await user.type(within(md).getByLabelText("上下文窗口"), "983616");
    expect((within(md).getByLabelText("上下文窗口") as HTMLInputElement).validity.stepMismatch).toBe(false);
    // the reasoning levels the model offers, and its default among them
    await user.click(
      within(md).getByRole("button", { name: "low", pressed: false }),
    );
    await user.click(
      within(md).getByRole("button", { name: "high", pressed: false }),
    );
    await user.click(within(md).getByRole("combobox", { name: "默认档" }));
    await user.click(await screen.findByRole("option", { name: "high" }));
    // web search per model: this one searches through Longx whatever the provider says
    await user.click(within(md).getByRole("combobox", { name: "联网搜索" }));
    await user.click(await screen.findByRole("option", { name: /Longx 代搜/ }));
    await user.click(within(md).getByRole("button", { name: "保存" }));
    await waitFor(() =>
      expect(createModel).toHaveBeenCalledWith(
        expect.objectContaining({
          input: expect.objectContaining({
            name: "GLM 5",
            upstreamId: "glm-5-turbo",
            providerId: "p2",
            contextWindow: 983616,
            reasoningLevels: ["low", "high"],
            reasoningEffort: "high",
            hostedWebSearch: false,
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

  test("models: a provider's own list (GET /models) is fetched into a checklist; picked ones become rows with what the list said", async () => {
    setViewport(1280);
    vi.mocked(discoverModels).mockResolvedValue(
      ok({
        ok: true,
        error: null,
        models: [
          { id: "deepseek-flash", name: "deepseek-flash", ownedBy: "deepseek", contextWindow: null, reasoningLevels: [], reasoningEffort: null, imageInput: false, installed: true },
          { id: "kimi-k3", name: "kimi-k3", ownedBy: "moonshot", contextWindow: null, reasoningLevels: [], reasoningEffort: null, imageInput: false, installed: false },
          { id: "x/y", name: "X Y", ownedBy: null, contextWindow: 32000, reasoningLevels: ["low", "high"], reasoningEffort: "low", imageInput: true, installed: false },
        ],
      }) as never,
    );
    const user = userEvent.setup();
    renderAt("/settings/models");
    const card = await screen.findByTestId("provider-p1");
    await user.click(within(card).getByRole("button", { name: "Prov 的操作" }));
    await user.click(await screen.findByRole("menuitem", { name: "从接口获取模型" }));
    const dialog = await screen.findByRole("dialog");
    await waitFor(() => expect(discoverModels).toHaveBeenCalledWith(expect.objectContaining({ input: { id: "p1" } })));
    // the installed one is out; the rest pickable, with their facts
    await waitFor(() => expect(within(dialog).getByText("kimi-k3")).toBeInTheDocument());
    expect(within(dialog).queryByText("deepseek-flash")).not.toBeInTheDocument();
    expect(within(dialog).getByText("X Y")).toBeInTheDocument();
    expect(dialog).toHaveTextContent("32k");
    // filter, pick, add
    await user.type(within(dialog).getByLabelText("筛选"), "kimi");
    expect(within(dialog).queryByText("X Y")).not.toBeInTheDocument();
    await user.clear(within(dialog).getByLabelText("筛选"));
    await user.click(within(dialog).getByText("X Y"));
    await user.click(within(dialog).getByRole("button", { name: /添加 1 个/ }));
    await waitFor(() =>
      expect(createModel).toHaveBeenCalledWith(
        expect.objectContaining({ input: expect.objectContaining({ providerId: "p1", upstreamId: "x/y", name: "X Y", contextWindow: 32000, reasoningLevels: ["low", "high"], reasoningEffort: "low" }) }),
      ),
    );
    vi.mocked(discoverModels).mockResolvedValue(ok({ ok: true, error: null, models: [] }) as never);
  });

  test("models: the endpoint refusing the list is said in the dialog", async () => {
    setViewport(1280);
    vi.mocked(discoverModels).mockResolvedValue(ok({ ok: false, error: "401 bad key", models: [] }) as never);
    const user = userEvent.setup();
    renderAt("/settings/models");
    const card = await screen.findByTestId("provider-p1");
    await user.click(within(card).getByRole("button", { name: "Prov 的操作" }));
    await user.click(await screen.findByRole("menuitem", { name: "从接口获取模型" }));
    const dialog = await screen.findByRole("dialog");
    await waitFor(() => expect(dialog).toHaveTextContent("401 bad key"));
    vi.mocked(discoverModels).mockResolvedValue(ok({ ok: true, error: null, models: [] }) as never);
  });

  test("models: the reviewer model — a model and one of its levels, or the thread's own", async () => {
    setViewport(1280);
    const user = userEvent.setup();
    renderAt("/settings/models");
    const card = await screen.findByTestId("review-model");
    // the thread's own model by default: no level to pick
    expect(within(card).getByRole("combobox", { name: "自动审核用的模型" })).toHaveTextContent("和会话相同");
    expect(within(card).queryByRole("combobox", { name: "思考档位" })).not.toBeInTheDocument();

    await user.click(within(card).getByRole("combobox", { name: "自动审核用的模型" }));
    // what the server answers once the pick is saved (the write refetches the settings)
    vi.mocked(reviewSettings).mockResolvedValue(ok({ modelSlug: "glm-5", effort: null }) as never);
    await user.click(await screen.findByRole("option", { name: "glm-5" }));
    await waitFor(() => expect(setReviewModel).toHaveBeenCalledWith(expect.objectContaining({ input: { modelSlug: "glm-5", effort: null } })));

    await waitFor(() => expect(within(card).getByRole("combobox", { name: "思考档位" })).toBeInTheDocument());
    await user.click(within(card).getByRole("combobox", { name: "思考档位" }));
    await user.click(await screen.findByRole("option", { name: "high" }));
    await waitFor(() => expect(setReviewModel).toHaveBeenLastCalledWith(expect.objectContaining({ input: { modelSlug: "glm-5", effort: "high" } })));
    vi.mocked(reviewSettings).mockResolvedValue(ok({ modelSlug: null, effort: null }) as never);
  });

  test("requests: the gateway's last requests — model, effort, tools, outcome — newest first", async () => {
    setViewport(1280);
    renderAt("/settings/requests");
    // the skeleton carries the test id until the data is in: query the rows on the screen
    const rows = await screen.findAllByTestId("request-row");
    const section = screen.getByTestId("section-requests");
    expect(rows).toHaveLength(2);
    expect(rows[0]).toHaveTextContent("deepseek-flash");
    expect(rows[0]).toHaveTextContent("deepseek-v4-flash");
    // the reasoning effort codex asked for, per request; absent = the model's default
    expect(rows[0]).toHaveTextContent("low");
    expect(rows[1]).toHaveTextContent("未指定");
    expect(rows[0]).toHaveTextContent("200");
    expect(rows[0]).toHaveTextContent("1 s");
    expect(rows[1]).toHaveTextContent("400");
    expect(rows[1]).toHaveTextContent("unknown model");
    // the tools behind a click
    const user = userEvent.setup();
    await user.click(within(rows[0]!).getByRole("button", { name: /详情/ }));
    expect(await within(section).findByText(/exec_command, memory/)).toBeInTheDocument();
    expect(within(section).getByText(/思考档位: low · summary auto/)).toBeInTheDocument();
  });

  test("tools: the built-in browser's private-network switch (a fake-ip network needs it)", async () => {
    setViewport(1280);
    const user = userEvent.setup();
    renderAt("/settings/tools");
    const card = await screen.findByTestId("browser-settings");
    const sw = within(card).getByRole("switch", { name: /私网|局域网/ });
    expect(sw).not.toBeChecked();
    await user.click(sw);
    await waitFor(() => expect(setBrowserPrivateNetwork).toHaveBeenCalledWith(expect.objectContaining({ input: { enabled: true } })));
    await waitFor(() => expect(within(card).getByRole("switch", { name: /私网|局域网/ })).toBeChecked());
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

  test("processes: every running codex with its cost and last use; an idle one can be stopped, a busy one is said so", async () => {
    setViewport(1280);
    const user = userEvent.setup();
    renderAt("/settings/processes");
    const section = await screen.findByTestId("section-processes");
    expect(section).toHaveTextContent("30 分钟");
    const one = await within(section).findByTestId("codex-process-id-1");
    expect(one).toHaveTextContent("App One");
    expect(one).toHaveTextContent("300 MB");
    expect(one).toHaveTextContent("12");
    const two = within(section).getByTestId("codex-process-id-2");
    expect(two).toHaveTextContent("1 轮进行中");
    await user.click(within(one).getByRole("button", { name: "停止" }));
    await waitFor(() => expect(stopCodex).toHaveBeenCalledWith(expect.objectContaining({ input: { id: "id-1", force: false } })));
    expect(listCodexProcesses).toHaveBeenCalled();
  });

  test("processes: nothing running is said, not an empty table", async () => {
    setViewport(1280);
    vi.mocked(listCodexProcesses).mockResolvedValue(ok({ idleAfterMs: null, processes: [] }) as never);
    renderAt("/settings/processes");
    const section = await screen.findByTestId("section-processes");
    await within(section).findByText("没有在运行的 codex");
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
        bwrap: "/usr/bin/bwrap",
        checkedAt: "2026-09-14T00:00:00Z",
      }) as never,
    );
    renderAt("/settings/sandbox");
    await waitFor(() =>
      expect(screen.getByTestId("section-sandbox")).toHaveTextContent("AppArmor"),
    );
    const section = screen.getByTestId("section-sandbox");
    expect(section).toHaveTextContent("apparmor_parser -r /etc/apparmor.d/longx-bwrap");
    // the profile covers the bwrap codex runs — the system one here — and the bundled path
    expect(section).toHaveTextContent("profile longx-system-bwrap /usr/bin/bwrap");
    expect(section).toHaveTextContent("codex-resources/bwrap flags=(unconfined)");
    expect(section).toHaveTextContent("codex 用的是 /usr/bin/bwrap");
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

  test("knowledge: the global docs are listed and edited, a shipped doc opens read-only, a new doc gets a template", async () => {
    setViewport(1280);
    const user = userEvent.setup();
    renderAt("/settings/knowledge");
    const section = await screen.findByTestId("section-knowledge");
    await within(section).findByText("About me");
    expect(within(section).getByText("Writing plugs")).toBeInTheDocument();
    expect(within(section).getByText("每轮注入")).toBeInTheDocument();

    // a global doc opens in the editor; a change is saved as the whole file
    await user.click(within(section).getByText("About me"));
    const editor = await within(section).findByTestId("code-editor");
    await waitFor(() => expect(editor.querySelector(".cm-content")).toHaveTextContent("Tabs, never spaces."));
    await user.click(editor.querySelector(".cm-content")!);
    await user.keyboard("!");
    await user.click(within(section).getByRole("button", { name: "保存" }));
    await waitFor(() =>
      expect(knowledgeWrite).toHaveBeenCalledWith(expect.objectContaining({ input: expect.objectContaining({ path: "global/me.md", content: expect.stringContaining("!") }) })),
    );
    // delete asks first
    await user.click(within(section).getByRole("button", { name: /删除/ }));
    await user.click(await screen.findByRole("button", { name: "删除" }));
    await waitFor(() => expect(knowledgeDelete).toHaveBeenCalledWith(expect.objectContaining({ input: { path: "global/me.md" } })));

    // a shipped doc is read-only
    await user.click(within(section).getByText("Writing plugs"));
    await within(section).findByText("出厂知识只读");
    expect(within(section).queryByRole("button", { name: "保存" })).not.toBeInTheDocument();
    await user.click(within(section).getByRole("button", { name: "关闭" }));

    // a new doc: a name, a template, straight into the editor
    await user.click(within(section).getByRole("button", { name: /新建/ }));
    await user.type(within(section).getByLabelText("文件名"), "tools/deploy");
    await user.click(within(await screen.findByTestId("knowledge-new")).getByRole("button", { name: "新建" }));
    await waitFor(() =>
      expect(knowledgeWrite).toHaveBeenCalledWith(expect.objectContaining({ input: expect.objectContaining({ path: "global/tools/deploy.md", content: expect.stringContaining("title: deploy") }) })),
    );
  });

  test("agent kernel: the team parameters are saved as one call, the global agent files are listed, edited and created from a template", async () => {
    setViewport(1280);
    const user = userEvent.setup();
    renderAt("/settings/agent");
    const section = await screen.findByTestId("section-agent");
    const settings = await within(section).findByTestId("agent-settings");
    const depth = within(settings).getByLabelText("派出深度上限") as HTMLInputElement;
    expect(depth.value).toBe("2");
    await user.clear(depth);
    await user.type(depth, "3");
    await user.click(within(settings).getByRole("button", { name: "保存" }));
    await waitFor(() =>
      expect(setAgentSettings).toHaveBeenCalledWith(expect.objectContaining({ input: expect.objectContaining({ maxDepth: 3, maxChildren: 4, idleMinutes: 30, childModel: null }) })),
    );

    // a file opens in the editor; a change is saved whole; delete asks first
    const files = within(section).getByTestId("agent-files");
    await user.click(within(files).getByText("agents/writer/agent.exs"));
    const editor = await within(section).findByTestId("code-editor");
    await waitFor(() => expect(editor.querySelector(".cm-content")).toHaveTextContent("writes"));
    await user.click(editor.querySelector(".cm-content")!);
    await user.keyboard("!");
    await user.click(within(within(section).getByTestId("agent-file-editor")).getByRole("button", { name: "保存" }));
    await waitFor(() =>
      expect(agentWriteFile).toHaveBeenCalledWith(expect.objectContaining({ input: expect.objectContaining({ path: "agents/writer/agent.exs", content: expect.stringContaining("!") }) })),
    );
    await user.click(within(section).getByRole("button", { name: /删除/ }));
    await user.click(await screen.findByRole("button", { name: "删除" }));
    await waitFor(() => expect(agentDeleteFile).toHaveBeenCalledWith(expect.objectContaining({ input: { path: "agents/writer/agent.exs" } })));

    // a new role file gets the declaration template
    await user.click(within(section).getByRole("button", { name: /新建文件/ }));
    await user.type(within(section).getByLabelText("路径"), "agents/poet/agent.exs");
    await user.click(within(await screen.findByTestId("agent-file-new")).getByRole("button", { name: "新建" }));
    await waitFor(() =>
      expect(agentWriteFile).toHaveBeenCalledWith(expect.objectContaining({ input: expect.objectContaining({ path: "agents/poet/agent.exs", content: expect.stringContaining("poet") }) })),
    );
  });

  test("memory: the index is editable, the notes are listed with their origin and can be deleted, search finds lines", async () => {
    setViewport(1280);
    const user = userEvent.setup();
    renderAt("/settings/memory");
    const section = await screen.findByTestId("section-memory");
    // the pipeline's state
    await within(section).findByText("2 条待整理");
    await within(section).findByText(/5 条已整理进 MEMORY.md/);
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
        ok({ ...upgradeIdle, latest: "0.2.0", available: true, stage: "downloading", target: "0.2.0", progress: { received: 150000000, total: 500000000 } }) as never,
      )
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
    const bar = await within(section).findByRole("progressbar");
    expect(bar).toHaveAttribute("aria-valuenow", "150000000");
    expect(section).toHaveTextContent("143 MB / 477 MB");
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
