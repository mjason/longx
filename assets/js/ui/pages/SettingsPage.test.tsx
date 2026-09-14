import { screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, test, vi } from "vitest";
import { renderAt, setViewport } from "@/ui/test-utils";
import { ok, rpcMock, socketMock } from "@/ui/test-mocks";

vi.mock("@/ash_rpc", async () => (await import("@/ui/test-mocks")).rpcMock());
vi.mock("@/core/socket", async () => (await import("@/ui/test-mocks")).socketMock());
import { checkModel, createModel, createProvider, deleteModel, listModels, makeDefaultModel, probeSandbox, setToolEnabled, updateSearchProvider } from "@/ash_rpc";
import { model } from "@/ui/test-mocks";
import { within } from "@testing-library/react";

describe("SettingsPage", () => {
  test("phone: a list of sections, then the section", async () => {
    setViewport(390);
    const user = userEvent.setup();
    const { router } = renderAt("/settings");
    await user.click(screen.getByRole("link", { name: /外观/ }));
    await waitFor(() => expect(router.state.location.pathname).toBe("/settings/appearance"));
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
    vi.mocked(listModels).mockResolvedValue(ok([model(1, { slug: "deepseek-flash", default: true }), model(2, { slug: "glm-5" })]) as never);
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

    await user.click(screen.getByRole("button", { name: "添加 Provider" }));
    const dialog = await screen.findByRole("dialog");
    await user.type(within(dialog).getByLabelText("名称"), "OpenAI");
    await user.type(within(dialog).getByLabelText("Base URL"), "https://api.openai.com/v1");
    await user.type(within(dialog).getByLabelText("API Key"), "sk-1");
    await user.click(within(dialog).getByRole("button", { name: "保存" }));
    await waitFor(() => expect(createProvider).toHaveBeenCalledWith(expect.objectContaining({ input: expect.objectContaining({ name: "OpenAI", slug: "openai", baseUrl: "https://api.openai.com/v1", apiKey: "sk-1" }) })));

    await user.click(within(glm).getByRole("button", { name: "添加模型" }));
    const md = await screen.findByRole("dialog");
    await user.type(within(md).getByLabelText("名称"), "GLM 5");
    await user.type(within(md).getByLabelText("模型 ID"), "glm-5-turbo");
    await user.clear(within(md).getByLabelText("上下文窗口"));
    await user.type(within(md).getByLabelText("上下文窗口"), "200000");
    await user.click(within(md).getByRole("button", { name: "保存" }));
    await waitFor(() => expect(createModel).toHaveBeenCalledWith(expect.objectContaining({ input: expect.objectContaining({ name: "GLM 5", upstreamId: "glm-5-turbo", providerId: "p2", contextWindow: 200000 }) })));
  });

  test("models: check, make default, delete (with a confirm)", async () => {
    setViewport(1280);
    const user = userEvent.setup();
    renderAt("/settings/models");
    const row = await screen.findByTestId("model-m2");
    await user.click(within(row).getByRole("button", { name: "检测" }));
    await waitFor(() => expect(checkModel).toHaveBeenCalledWith(expect.objectContaining({ input: { id: "m2" } })));
    await within(row).findByText(/321 ms/);
    await user.click(within(row).getByRole("button", { name: "设为默认" }));
    await waitFor(() => expect(makeDefaultModel).toHaveBeenCalledWith(expect.objectContaining({ identity: "m2" })));
    await user.click(within(row).getByRole("button", { name: "Model 2 的操作" }));
    await user.click(await screen.findByRole("menuitem", { name: "删除模型" }));
    await user.click(within(await screen.findByRole("alertdialog")).getByRole("button", { name: "删除" }));
    await waitFor(() => expect(deleteModel).toHaveBeenCalledWith(expect.objectContaining({ identity: "m2" })));
  });

  test("models: the search provider's key can be set", async () => {
    setViewport(1280);
    const user = userEvent.setup();
    renderAt("/settings/models");
    const search = await screen.findByTestId("search-provider");
    expect(search).toHaveTextContent("Tavily");
    await user.type(within(search).getByLabelText("API Key"), "tvly-1");
    await user.click(within(search).getByRole("button", { name: "保存" }));
    await waitFor(() => expect(updateSearchProvider).toHaveBeenCalledWith(expect.objectContaining({ identity: "s1", input: { apiKey: "tvly-1" } })));
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
    await waitFor(() => expect(setToolEnabled).toHaveBeenCalledWith(expect.objectContaining({ identity: "t1", input: { enabled: true } })));
    expect(within(screen.getByTestId("tool-builtin.browser_fetch")).getByRole("switch")).toBeChecked();
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

  test("desktop: categories beside the content, models first", async () => {
    setViewport(1280);
    const { router } = renderAt("/settings");
    await waitFor(() => expect(router.state.location.pathname).toBe("/settings/models"));
    expect(screen.getByRole("link", { name: "模型与 Provider" })).toHaveAttribute("aria-current", "page");
    expect(screen.getByTestId("section-models")).toBeInTheDocument();
  });
});
