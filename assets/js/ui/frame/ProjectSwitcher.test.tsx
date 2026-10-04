import { act, fireEvent, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, expect, test, vi } from "vitest";
import { renderAt, setViewport } from "@/ui/test-utils";
import { channel, ok, project, thread } from "@/ui/test-mocks";
import { _resetWorkbenchForTests } from "@/core/workbench";
import { setProjectPicker } from "@/core/projectNavigation";
import { queryKeys } from "@/core/projects";
import { commands } from "@/core/keys/registry";

vi.mock("@/core/api", async () => (await import("@/ui/test-mocks")).rpcMock());
vi.mock("@/core/socket", async () => (await import("@/ui/test-mocks")).socketMock());
import { getProject, listProjects, listRunningThreads, listThreads, readFile, startThread } from "@/core/api";

beforeEach(() => {
  localStorage.clear();
  _resetWorkbenchForTests();
  setProjectPicker(false);
  channel.reset();
  vi.mocked(getProject).mockImplementation(async args => ok(project(Number(String(args?.input?.slug ?? "").split("-").at(-1)) || 1)) as never);
  vi.mocked(listProjects).mockResolvedValue(ok([project(1), { ...project(2), pinned: true }, project(3), project(4)]) as never);
  vi.mocked(listThreads).mockImplementation(async args => ok([{ ...thread(args?.input?.projectId === "id-2" ? 2 : 1) }]) as never);
  vi.mocked(listRunningThreads).mockResolvedValue(ok({ threads: [{ id: "t3", projectId: "id-3", waiting: true }] }) as never);
  vi.mocked(startThread).mockClear();
});

test("desktop bar shows current, pinned, then active; idle recent projects stay in the searchable picker", async () => {
  setViewport(1280);
  const user = userEvent.setup();
  renderAt("/p/app-1/t/t1");
  const bar = await screen.findByTestId("project-switcher");
  await waitFor(() => expect(within(bar).getAllByRole("link").map(el => el.textContent)).toEqual(["App 1", "App 2", "App 3● 1"]));
  expect(within(bar).queryByText("App 4")).toBeNull();
  expect(within(bar).getByRole("link", { name: "App 1" })).toHaveAttribute("aria-current", "page");
  await user.click(within(bar).getByRole("button", { name: "全部项目" }));
  const dialog = await screen.findByRole("dialog", { name: "全部项目" });
  await user.type(within(dialog).getByRole("combobox"), "/srv/app-4");
  expect(within(dialog).getAllByRole("option")).toHaveLength(1);
  expect(within(dialog).getByRole("option")).toHaveTextContent("App 4");
});

test("phone uses a bottom selector and switching restores the target's saved conversation without starting another", async () => {
  setViewport(390);
  localStorage.setItem("longx:workbench:id-2", JSON.stringify({ tabs: [{ kind: "chat", threadId: "t2" }], active: "chat:t2" }));
  const user = userEvent.setup();
  const { router } = renderAt("/p/app-1/t/t1");
  const bar = await screen.findByTestId("project-switcher");
  expect(within(bar).queryAllByRole("link")).toHaveLength(0);
  await user.click(within(bar).getByRole("button", { name: "全部项目" }));
  const sheet = await screen.findByTestId("project-picker-sheet");
  await user.click(within(sheet).getByRole("option", { name: /App 2/ }));
  await waitFor(() => expect(router.state.location.pathname).toBe("/p/app-2/t/t2"));
  expect(startThread).not.toHaveBeenCalled();
});

test("an unpinned active project leaves the bar when its activity finishes, while pinned ones remain", async () => {
  setViewport(1280);
  const { client } = renderAt("/p/app-1/t/t1");
  const bar = await screen.findByTestId("project-switcher");
  await within(bar).findByRole("link", { name: /App 3/ });
  vi.mocked(listRunningThreads).mockResolvedValue(ok({ threads: [] }) as never);
  await act(async () => { await client.invalidateQueries({ queryKey: queryKeys.running }); });
  await waitFor(() => expect(within(bar).queryByRole("link", { name: /App 3/ })).toBeNull());
  expect(within(bar).getByRole("link", { name: /App 2/ })).toBeInTheDocument();
});

test("the existing project-switch command opens the same mobile selector", async () => {
  setViewport(390);
  renderAt("/p/app-1");
  await screen.findByTestId("project-switcher");
  await waitFor(() => expect(commands.available("project.switch")).toBe(true));
  await act(() => commands.run("project.switch"));
  expect(await screen.findByTestId("project-picker-sheet")).toBeInTheDocument();
});

test("text drafts are isolated between projects and restored on return", async () => {
  setViewport(1280);
  const user = userEvent.setup();
  const { router } = renderAt("/p/app-1/t/t1");
  await user.type(await screen.findByRole("textbox", { name: "随心输入" }), "项目一的草稿");
  await user.click(within(screen.getByTestId("project-switcher")).getByRole("link", { name: /App 2/ }));
  await waitFor(() => expect(router.state.location.pathname).toBe("/p/app-2"));
  expect(screen.getByRole("textbox", { name: "随心输入" })).toHaveValue("");
  await user.type(screen.getByRole("textbox", { name: "随心输入" }), "项目二的草稿");
  await act(() => router.navigate("/p/app-1"));
  await waitFor(() => expect(router.state.location.pathname).toBe("/p/app-1/t/t1"));
  await waitFor(() => expect(screen.getByRole("textbox", { name: "随心输入" })).toHaveValue("项目一的草稿"));
});

test("an unsaved file buffer survives a project round trip and never leaks into the same path in another project", async () => {
  setViewport(1280);
  vi.mocked(readFile).mockResolvedValue(ok({ path: "a.ex", content: "original\n", size: 9, binary: false, truncated: false }) as never);
  for (const id of ["id-1", "id-2"]) localStorage.setItem(`longx:workbench:${id}`, JSON.stringify({
    tabs: [{ kind: "file", path: "a.ex" }], active: "file:a.ex",
  }));
  const user = userEvent.setup();
  const { router } = renderAt("/p/app-1");
  const editor = await screen.findByTestId("editor-tab");
  const content = await waitFor(() => {
    const el = editor.querySelector(".cm-content");
    expect(el).toHaveTextContent("original");
    return el!;
  });
  await user.click(content);
  await user.keyboard("!");
  expect(screen.getByTestId("save-file")).toBeEnabled();
  await user.click(within(screen.getByTestId("project-switcher")).getByRole("link", { name: /App 2/ }));
  await waitFor(() => expect(router.state.location.pathname).toBe("/p/app-2"));
  await waitFor(() => expect(screen.getByTestId("save-file")).toBeDisabled());
  expect(screen.getByTestId("editor-tab").querySelector(".cm-content")).not.toHaveTextContent("!");
  await act(() => router.navigate("/p/app-1"));
  await waitFor(() => expect(screen.getByTestId("save-file")).toBeEnabled());
  expect(screen.getByTestId("editor-tab").querySelector(".cm-content")).toHaveTextContent("!");
});

test("a staged attachment prevents leaving its runtime instead of silently losing the file", async () => {
  setViewport(1280);
  const user = userEvent.setup();
  const { router } = renderAt("/p/app-1/t/t1");
  await screen.findByRole("textbox", { name: "随心输入" });
  fireEvent.drop(document.querySelector("[data-slot=aui_composer-shell]")!, {
    dataTransfer: { files: [new File(["image"], "shot.png", { type: "image/png" })], types: ["Files"] },
  });
  await screen.findByRole("button", { name: /image attachment/i });
  await user.click(within(screen.getByTestId("project-switcher")).getByRole("link", { name: /App 2/ }));
  expect(router.state.location.pathname).toBe("/p/app-1/t/t1");
  expect(screen.getByRole("button", { name: /image attachment/i })).toBeInTheDocument();
  expect(await screen.findByText(/当前有未发送的附件/)).toBeInTheDocument();
});
