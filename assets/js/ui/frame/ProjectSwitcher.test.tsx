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
import { getProject, interruptTurn, listProjects, listRunningThreads, listThreads, readFile, sendMessage, startThread } from "@/core/api";

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
  vi.mocked(sendMessage).mockClear();
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

test("an image draft survives a project round trip without blocking navigation or leaking into another project", async () => {
  setViewport(1280);
  const user = userEvent.setup();
  const { router } = renderAt("/p/app-1/t/t1", { strict: true });
  await screen.findByRole("textbox", { name: "随心输入" });
  fireEvent.drop(document.querySelector("[data-slot=aui_composer-shell]")!, {
    dataTransfer: { files: [new File(["image"], "shot.png", { type: "image/png" })], types: ["Files"] },
  });
  await screen.findByRole("button", { name: /image attachment/i });
  await user.click(within(screen.getByTestId("project-switcher")).getByRole("link", { name: /App 2/ }));
  await waitFor(() => expect(router.state.location.pathname).toBe("/p/app-2"));
  expect(screen.queryByRole("button", { name: /image attachment/i })).not.toBeInTheDocument();
  await act(() => router.navigate("/p/app-1"));
  await waitFor(() => expect(router.state.location.pathname).toBe("/p/app-1/t/t1"));
  expect(screen.getByRole("button", { name: /image attachment/i })).toBeInTheDocument();
  await act(() => channel.replyTo("thread:thr_1", "ok", {
    thread_id: "thr_1", seq: 1, thread: null, turn: null, status: null, token_usage: null, items: [], pending_requests: [],
  }));
  await user.click(screen.getByRole("button", { name: "发送" }));
  await waitFor(() => expect(sendMessage).toHaveBeenCalledWith(expect.objectContaining({
    input: expect.objectContaining({ threadId: "t1", text: "", images: [expect.stringContaining("data:image/png;base64,")] }),
  })));
});

test("an upload in progress can finish after switching projects and is restored without uploading twice", async () => {
  setViewport(1280);
  let finish!: (response: Response) => void;
  const upload = vi.fn(() => new Promise<Response>(resolve => { finish = resolve; }));
  const originalFetch = globalThis.fetch;
  globalThis.fetch = upload;
  try {
    const user = userEvent.setup();
    const { router } = renderAt("/p/app-1/t/t1");
    await screen.findByRole("textbox", { name: "随心输入" });
    fireEvent.drop(document.querySelector("[data-slot=aui_composer-shell]")!, {
      dataTransfer: { files: [new File(["pdf"], "report.pdf", { type: "application/pdf" })], types: ["Files"] },
    });
    await waitFor(() => expect(upload).toHaveBeenCalledOnce());
    await user.click(within(screen.getByTestId("project-switcher")).getByRole("link", { name: /App 2/ }));
    await waitFor(() => expect(router.state.location.pathname).toBe("/p/app-2"));
    await act(async () => finish(new Response(JSON.stringify({
      name: "report.pdf", path: "/data/attachments/id-1/report.pdf", bytes: 3,
    }), { status: 200 })));
    await act(() => router.navigate("/p/app-1"));
    await waitFor(() => expect(router.state.location.pathname).toBe("/p/app-1/t/t1"));
    await screen.findByRole("button", { name: /file attachment/i });
    expect(upload).toHaveBeenCalledOnce();
    await act(() => channel.replyTo("thread:thr_1", "ok", {
      thread_id: "thr_1", seq: 1, thread: null, turn: null, status: null, token_usage: null, items: [], pending_requests: [],
    }));
    await user.click(screen.getByRole("button", { name: "发送" }));
    await waitFor(() => expect(sendMessage).toHaveBeenCalledWith(expect.objectContaining({
      input: expect.objectContaining({ threadId: "t1", text: expect.stringContaining("/data/attachments/id-1/report.pdf") }),
    })));
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("a queued image keeps its owner and sends exactly once when that turn finishes in the background", async () => {
  setViewport(1280);
  const user = userEvent.setup();
  const { router } = renderAt("/p/app-1/t/t1");
  await screen.findByRole("textbox", { name: "随心输入" });
  await waitFor(() => expect(channel.topics).toContain("thread:thr_1"));
  await act(() => channel.replyTo("thread:thr_1", "ok", {
    thread_id: "thr_1", seq: 1, thread: null, turn: { id: "turn_1", status: "inProgress" },
    status: null, token_usage: null, items: [], pending_requests: [],
  }));
  fireEvent.drop(document.querySelector("[data-slot=aui_composer-shell]")!, {
    dataTransfer: { files: [new File(["queued image"], "queued.png", { type: "image/png" })], types: ["Files"] },
  });
  await screen.findByRole("button", { name: /image attachment/i });
  await user.click(screen.getByRole("button", { name: "加入队列" }));
  await screen.findByTestId("message-queue");
  expect(sendMessage).not.toHaveBeenCalled();
  await user.click(within(screen.getByTestId("project-switcher")).getByRole("link", { name: /App 2/ }));
  await waitFor(() => expect(router.state.location.pathname).toBe("/p/app-2"));
  expect(screen.queryByTestId("message-queue")).not.toBeInTheDocument();
  await act(() => channel.deliverTo("thread:thr_1", "event", {
    seq: 2, method: "turn/completed", params: { turn: { id: "turn_1", status: "completed" } },
  }));
  await waitFor(() => expect(sendMessage).toHaveBeenCalledWith(expect.objectContaining({
    input: expect.objectContaining({ threadId: "t1", text: "", images: [expect.stringContaining("data:image/png;base64,")] }),
  })));
  expect(sendMessage).toHaveBeenCalledOnce();
  expect(router.state.location.pathname).toBe("/p/app-2");
});

test("switching away and back preserves a stopped queue without auto-sending it", async () => {
  setViewport(1280);
  const user = userEvent.setup();
  const { router } = renderAt("/p/app-1/t/t1");
  await screen.findByRole("textbox", { name: "随心输入" });
  await waitFor(() => expect(channel.topics).toContain("thread:thr_1"));
  await act(() => channel.replyTo("thread:thr_1", "ok", {
    thread_id: "thr_1", seq: 1, thread: null, turn: { id: "turn_1", status: "inProgress" },
    status: null, token_usage: null, items: [
      { id: "c1", type: "commandExecution", turnId: "turn_1", command: "sleep 30", cwd: "/p", status: "inProgress" },
    ], pending_requests: [],
  }));
  await user.type(screen.getByRole("textbox", { name: "随心输入" }), "paused message{Enter}");
  expect(await screen.findByTestId("message-queue")).toHaveTextContent("paused message");
  await user.click(screen.getByRole("button", { name: /停止/ }));
  expect(interruptTurn).toHaveBeenCalled();
  await act(() => channel.deliverTo("thread:thr_1", "event", {
    seq: 2, method: "turn/completed", params: { turn: { id: "turn_1", status: "interrupted" } },
  }));
  await user.click(within(screen.getByTestId("project-switcher")).getByRole("link", { name: /App 2/ }));
  await waitFor(() => expect(router.state.location.pathname).toBe("/p/app-2"));
  await act(() => router.navigate("/p/app-1"));
  await waitFor(() => expect(router.state.location.pathname).toBe("/p/app-1/t/t1"));
  expect(await screen.findByTestId("message-queue")).toHaveTextContent("paused message");
  expect(sendMessage).not.toHaveBeenCalled();
});
