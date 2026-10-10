import {
  act,
  fireEvent,
  screen,
  waitFor,
  within,
} from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, test, vi } from "vitest";
import { renderAt, setViewport } from "@/ui/test-utils";
import { _resetFrameStoreForTests } from "@/core/frame";
import { _resetWorkbenchForTests } from "@/core/workbench";
import { rememberScroll } from "@/core/workspaceMemory";
import { commands } from "@/core/keys/registry";
import { agentDefinitionData, channel, failed, model, ok, thread, session } from "@/ui/test-mocks";

vi.mock("@/core/api", async () => (await import("@/ui/test-mocks")).rpcMock());
vi.mock("sonner", async (importOriginal) => {
  const mod = await importOriginal<typeof import("sonner")>();
  return { ...mod, toast: Object.assign(vi.fn(), mod.toast, { warning: vi.fn(), success: vi.fn(), error: vi.fn(), info: vi.fn() }) };
});
import { toast } from "sonner";
vi.mock("@/core/socket", async () =>
  (await import("@/ui/test-mocks")).socketMock(),
);
import {
  agentDefinition,
  answerRequest,
  clearGoal,
  getThread,
  listModels,
  listSubagents,
  listThreads,
  interruptTurn,
  releaseWaiting,
  releaseWaitingBatch,
  retractTurn,
  steerTurn,
  searchFiles,
  sendMessage,
  setGoal,
  startThread,
  directory,
  modelAliases,
  projectJobs,
  threadJobOutput,
  stopThreadJob,
  setThreadJobPurpose,
} from "@/core/api";
import { queryKeys } from "@/core/projects";
import i18n from "@/core/i18n";

const snapshot = {
  thread_id: "thr_1",
  seq: 3,
  thread: { id: "thr_1" },
  turn: { id: "turn_1", status: "completed" },
  status: null,
  token_usage: null,
  items: [
    {
      id: "u1",
      type: "userMessage",
      turnId: "turn_1",
      content: [{ type: "text", text: "run the tests" }],
    },
    {
      id: "c1",
      type: "commandExecution",
      turnId: "turn_1",
      command: "mix test",
      cwd: "/p",
      status: "completed",
      exitCode: 0,
      aggregatedOutput: "12 tests, 0 failures\n",
    },
    {
      id: "a1",
      type: "agentMessage",
      turnId: "turn_1",
      text: "All **green**.",
    },
  ],
  pending_requests: [],
};

async function open(path = "/p/app-1/t/t1") {
  const r = renderAt(path);
  await waitFor(() => expect(channel.topics).toContain("thread:thr_1"));
  act(() => channel.reply("ok", snapshot));
  await screen.findByText("run the tests");
  return r;
}

describe("ThreadPage", () => {
  test("multiple required jobs keep an idle conversation unfinished; independent services stay top-right", async () => {
    const user = userEvent.setup();
    const job = (name: string, activity: string, purpose = "wait") => ({
      name, run: `run-${name}`, cmd: "example", status: activity === "waiting" ? "running" : "exited",
      threadId: "t1", rootThreadId: "t1", threadTitle: null, purpose, activity,
      exitCode: 0, reason: null, startedAt: null, finishedAt: null,
    });
    let jobs = [job("tests", "waiting"), job("build", "pending"), job("server", "waiting", "background")];
    vi.mocked(projectJobs).mockImplementation(async () => ok({ jobs }) as never);
    const { client } = await open();
    const status = await screen.findByTestId("job-work-status");
    expect(screen.getByTestId("turn-bar")).toContainElement(status);
    expect(status).toHaveTextContent("等待任务结果 · 2");
    expect(screen.getByRole("button", { name: "后台 1" })).toBeInTheDocument();
    await user.click(within(status).getByRole("button", { name: /查看任务/ }));
    const details = await screen.findByTestId("job-work-popover");
    expect(details).toHaveTextContent("1 项运行中，1 项待处理");
    expect(details).toHaveTextContent("建议等最终汇总后再验收");
    expect(within(details).getAllByTestId("thread-job-row")).toHaveLength(2);
    expect(details).not.toHaveTextContent("server");
    await user.keyboard("{Escape}");
    await user.click(screen.getByRole("button", { name: "后台 1" }));
    const background = await screen.findByTestId("thread-background-popover");
    expect(background).toHaveTextContent("server");
    expect(background).toHaveTextContent("不计入等待结果");
    await user.click(within(background).getByRole("button", { name: "查看日志" }));
    expect(await within(background).findByText("example job log")).toBeInTheDocument();
    expect(threadJobOutput).toHaveBeenCalledWith(expect.objectContaining({ input: { threadId: "t1", name: "server", run: "run-server" } }));
    await user.keyboard("{Escape}");
    jobs = [job("tests", "complete"), job("build", "processing"), job("server", "waiting", "background")];
    await act(async () => { await client.invalidateQueries({ queryKey: queryKeys.projectJobs("id-1") }); });
    await waitFor(() => expect(status).toHaveTextContent("正在处理结果 · 1"));
    jobs = [job("tests", "complete"), job("build", "complete"), job("server", "waiting", "background")];
    await act(async () => { await client.invalidateQueries({ queryKey: queryKeys.projectJobs("id-1") }); });
    await waitFor(() => expect(screen.queryByTestId("job-work-status")).not.toBeInTheDocument());
    expect(screen.getByRole("button", { name: "后台 1" })).toBeInTheDocument();
  });

  test("job stop and purpose changes require confirmation and keep the exact run; copy changes language live", async () => {
    const user = userEvent.setup();
    vi.mocked(projectJobs).mockResolvedValue(ok({ jobs: [{
      name: "verify", run: "r1", cmd: "sleep 30", threadId: "t1", rootThreadId: "t1",
      status: "running", purpose: "wait", activity: "waiting", startedAt: null, finishedAt: null,
    }] }) as never);
    await open();
    const rail = await screen.findByTestId("job-work-status");
    await user.click(within(rail).getByRole("button", { name: /查看任务/ }));
    const status = await screen.findByTestId("job-work-popover");
    await user.click(within(status).getByRole("button", { name: "停止任务" }));
    expect(screen.getByRole("alertdialog")).toHaveTextContent("不会自动重跑");
    await user.click(screen.getByRole("button", { name: "取消" }));
    expect(stopThreadJob).not.toHaveBeenCalled();
    await user.click(within(status).getByRole("button", { name: "停止任务" }));
    await user.click(screen.getByRole("button", { name: "确认停止" }));
    await waitFor(() => expect(stopThreadJob).toHaveBeenCalledWith(expect.objectContaining({ input: { threadId: "t1", name: "verify", run: "r1" } })));
    await user.click(within(status).getByRole("button", { name: "任务用途 verify" }));
    expect(screen.getByRole("alertdialog")).toHaveTextContent("不再阻止本次工作完成");
    await user.click(screen.getByRole("button", { name: "确认更改" }));
    await waitFor(() => expect(setThreadJobPurpose).toHaveBeenCalledWith(expect.objectContaining({ input: { threadId: "t1", name: "verify", run: "r1", purpose: "background" } })));
    try {
      await act(async () => { await i18n.changeLanguage("en"); });
      expect(status).toHaveTextContent("Awaiting results");
      expect(status).toHaveTextContent("Wait for the final summary");
    } finally {
      await act(async () => { await i18n.changeLanguage("zh-CN"); });
    }
  });

  test("a pending result can be resumed explicitly without discarding the composer draft", async () => {
    const user = userEvent.setup();
    vi.mocked(projectJobs).mockResolvedValue(ok({ jobs: [{
      name: "result", run: "r1", cmd: "true", threadId: "t1", rootThreadId: "t1",
      status: "exited", purpose: "wait", activity: "pending", notify: true,
      startedAt: null, finishedAt: null,
    }] }) as never);
    await open();
    const status = await screen.findByTestId("job-work-status");
    expect(status).toHaveTextContent("结果待处理");
    const composer = screen.getByRole("textbox", { name: "随心输入" });
    await user.type(composer, "保留这份草稿");
    await user.click(within(status).getByRole("button", { name: /查看任务/ }));
    const details = await screen.findByTestId("job-work-popover");
    expect(details).toHaveTextContent("结果已到但尚未确认");
    expect(sendMessage).not.toHaveBeenCalled();
    expect(composer).toHaveValue("保留这份草稿");
    await user.click(within(details).getByRole("button", { name: "继续检查结果" }));
    await waitFor(() => expect(sendMessage).toHaveBeenCalledWith(expect.objectContaining({
      input: expect.objectContaining({ text: "继续检查待处理的任务结果，确认后再汇总；不要重跑我已停止的任务。" }),
    })));
    expect(sendMessage).toHaveBeenCalledTimes(1);
    expect(composer).toHaveValue("保留这份草稿");
  });

  test("already reviewed incomplete work stays visible without blocking a new message", async () => {
    const user = userEvent.setup();
    vi.mocked(projectJobs).mockResolvedValue(ok({ jobs: [{
      name: "failed", run: "r1", cmd: "false", threadId: "t1", rootThreadId: "t1",
      status: "exited", purpose: "wait", activity: "incomplete", review: "incomplete",
      startedAt: null, finishedAt: null,
    }] }) as never);
    await open();
    await screen.findByTestId("job-work-status");
    await user.type(screen.getByRole("textbox", { name: "随心输入" }), "新消息{Enter}");
    await waitFor(() => expect(sendMessage).toHaveBeenCalledTimes(1));
    expect(screen.queryByTestId("message-queue")).not.toBeInTheDocument();
    expect(screen.getByTestId("job-work-status")).toBeInTheDocument();
  });

  test("typing with unfinished work is quiet; sending queues and explicit insertion keeps the original message", async () => {
    const user = userEvent.setup();
    vi.mocked(projectJobs).mockResolvedValue(ok({ jobs: [{
      name: "verify", run: "r1", cmd: "true", threadId: "t1", rootThreadId: "t1",
      status: "exited", purpose: "wait", activity: "incomplete",
      startedAt: null, finishedAt: null,
    }] }) as never);
    const { client } = await open();
    await screen.findByTestId("job-work-status");
    vi.mocked(toast.warning).mockClear();
    const composer = screen.getByRole("textbox", { name: "随心输入" });
    await user.type(composer, "继续处理监控消息");
    expect(toast.warning).not.toHaveBeenCalled();
    await user.type(composer, "，不要改顺序");
    expect(toast.warning).not.toHaveBeenCalled();
    await user.keyboard("{Enter}");
    const queue = await screen.findByTestId("message-queue");
    expect(queue).toHaveTextContent("任务收尾后自动发送，也可立即插入");
    expect(queue).toHaveTextContent("继续处理监控消息，不要改顺序");
    expect(sendMessage).not.toHaveBeenCalled();
    vi.mocked(steerTurn).mockResolvedValueOnce(failed("not_running") as never);
    await user.click(within(queue).getByRole("button", { name: "插入" }));
    await waitFor(() => expect(sendMessage).toHaveBeenCalledWith(expect.objectContaining({
      input: expect.objectContaining({ text: "继续处理监控消息，不要改顺序" }),
    })));
    expect(releaseWaiting).not.toHaveBeenCalled();
    expect(releaseWaitingBatch).not.toHaveBeenCalled();
    vi.mocked(projectJobs).mockResolvedValue(ok({ jobs: [] }) as never);
    await act(async () => { await client.invalidateQueries({ queryKey: queryKeys.projectJobs("id-1") }); });
    await waitFor(() => expect(screen.queryByTestId("job-work-status")).not.toBeInTheDocument());
  });

  test("queued messages wait through task exit and result processing, then send once when required work is complete", async () => {
    const user = userEvent.setup();
    const job = {
      name: "verify", run: "r1", cmd: "true", threadId: "t1", rootThreadId: "t1",
      status: "running", purpose: "wait", activity: "waiting",
      startedAt: null, finishedAt: null,
    };
    vi.mocked(projectJobs).mockResolvedValue(ok({ jobs: [job] }) as never);
    const { client } = await open();
    await screen.findByTestId("job-work-status");
    await user.type(screen.getByRole("textbox", { name: "随心输入" }), "结果处理完再做这个{Enter}");
    expect(await screen.findByTestId("message-queue")).toHaveTextContent("结果处理完再做这个");
    expect(screen.queryByRole("button", { name: "停止" })).not.toBeInTheDocument();
    expect(sendMessage).not.toHaveBeenCalled();
    for (const activity of ["pending", "processing"]) {
      vi.mocked(projectJobs).mockResolvedValue(ok({ jobs: [{ ...job, status: "exited", activity }] }) as never);
      await act(async () => { await client.invalidateQueries({ queryKey: queryKeys.projectJobs("id-1") }); });
      expect(sendMessage).not.toHaveBeenCalled();
      expect(screen.getByTestId("message-queue")).toHaveTextContent("结果处理完再做这个");
    }
    vi.mocked(projectJobs).mockResolvedValue(ok({ jobs: [{ ...job, status: "exited", activity: "complete" }] }) as never);
    await act(async () => { await client.invalidateQueries({ queryKey: queryKeys.projectJobs("id-1") }); });
    await waitFor(() => expect(sendMessage).toHaveBeenCalledTimes(1));
    expect(sendMessage).toHaveBeenCalledWith(expect.objectContaining({
      input: expect.objectContaining({ threadId: "t1", text: "结果处理完再做这个" }),
    }));
    expect(screen.queryByTestId("message-queue")).not.toBeInTheDocument();
  });

  test("independent monitoring services do not warn when typing", async () => {
    const user = userEvent.setup();
    vi.mocked(projectJobs).mockResolvedValue(ok({ jobs: [{
      name: "monitor", run: "r1", cmd: "monitor", threadId: "t1", rootThreadId: "t1",
      status: "running", purpose: "background", activity: "waiting",
      startedAt: null, finishedAt: null,
    }] }) as never);
    await open();
    await screen.findByRole("button", { name: "后台 1" });
    vi.mocked(toast.warning).mockClear();
    await user.type(screen.getByRole("textbox", { name: "随心输入" }), "照常聊天");
    expect(toast.warning).not.toHaveBeenCalled();
    expect(screen.queryByTestId("job-work-status")).not.toBeInTheDocument();
  });

  test("manual compaction stays busy during retries and exposes failure without a success marker", async () => {
    await open();
    act(() => channel.deliver("event", {
      seq: 4, method: "turn/progress",
      params: { turnId: null, progress: { kind: "compactionRetry", name: "response protection is unavailable", bytes: 0, attempt: 1, limit: 3 } },
    }));
    expect(screen.getByTestId("turn-bar")).toHaveTextContent("压缩失败，正在重试（1/3）");
    act(() => {
      channel.deliver("event", { seq: 5, method: "turn/progress", params: { turnId: null, progress: null } });
      channel.deliver("event", {
        seq: 6, method: "item/completed", params: { item: {
          id: "cf1", type: "contextCompactionFailed", turnId: "turn_1", error: "response protection is unavailable",
        } },
      });
    });
    expect(await screen.findByTestId("compaction-failed")).toHaveTextContent("上下文压缩失败，历史已保留");
    expect(screen.getByTestId("compaction-failed")).not.toHaveTextContent("response protection is unavailable");
    await userEvent.click(screen.getByRole("button", { name: "查看错误" }));
    expect(await screen.findByTestId("request-error-details")).toHaveTextContent("response protection is unavailable");
    expect(screen.queryByTestId("compaction")).not.toBeInTheDocument();
  });

  test("the browser tab names the conversation, truncates long names, and resets on leaving", async () => {
    vi.mocked(listThreads).mockResolvedValue(ok([{ ...thread(1), title: "  修复\n标签页 " + "😀".repeat(30) }]) as never);
    const { router } = await open();
    await waitFor(() => expect(document.title).toBe("修复 标签页 " + "😀".repeat(17) + "… · Longx"));
    await act(async () => { await router.navigate("/p/app-1", { state: { newChat: true } }); });
    await waitFor(() => expect(document.title).toBe("Longx"));
  });

  test("the browser tab falls back to the conversation preview and resets on unmount", async () => {
    const { unmount } = await open();
    await waitFor(() => expect(document.title).toBe("thread 1 · Longx"));
    unmount();
    expect(document.title).toBe("Longx");
  });

  test("message copying uses the shared selection fallback when the Clipboard API refuses", async () => {
    const user = userEvent.setup();
    await open();
    Object.defineProperty(navigator, "clipboard", {
      value: { writeText: vi.fn().mockRejectedValue(new Error("denied")) },
      configurable: true,
    });
    const exec = vi.fn(() => {
      expect((document.activeElement as HTMLTextAreaElement).value).toBe("All **green**.");
      return true;
    });
    const previous = document.execCommand;
    document.execCommand = exec;
    try {
      await user.click(screen.getByRole("button", { name: "复制" }));
      await waitFor(() => expect(exec).toHaveBeenCalledWith("copy"));
    } finally {
      document.execCommand = previous;
    }
  });

  beforeEach(() => {
    localStorage.clear();
    _resetFrameStoreForTests();
    _resetWorkbenchForTests();
    channel.reset();
    vi.mocked(sendMessage).mockClear();
    vi.mocked(steerTurn).mockClear();
    vi.mocked(listThreads).mockResolvedValue(ok([thread(1)]) as never);
    setViewport(1280);
  });

  // turns `from`..`to` as the server's items: a question and an answer each
  const turnItems = (from: number, to: number) =>
    Array.from({ length: to - from + 1 }, (_, k) => from + k).flatMap((i) => [
      { id: `u${i}`, type: "userMessage", turnId: `turn_${i}`, content: [{ type: "text", text: `问题 ${i}` }] },
      { id: `a${i}`, type: "agentMessage", turnId: `turn_${i}`, text: `回答 ${i}` },
    ]);
  const none = { items: 0, turns: 0, partial: 0, activities: [] };

  test("a long thread opens on the tail the server sent; the edge above says what waits there and fetches it from the server on request, a page at a time or all of it", async () => {
    renderAt("/p/app-1/t/t1");
    await waitFor(() => expect(channel.topics).toContain("thread:thr_1"));
    act(() => channel.reply("ok", { ...snapshot, items: turnItems(41, 45), earlier: { items: 80, turns: 40, partial: 0, activities: [] } }));
    await screen.findByText("问题 45");
    expect(screen.queryByText("问题 40")).not.toBeInTheDocument();
    const edge = screen.getByTestId("history-edge");
    expect(edge).toHaveTextContent("还有 40 轮更早的对话");

    const user = userEvent.setup();
    await user.click(within(edge).getByRole("button", { name: /显示更早 80 条/ }));
    // asked of the server: the page before the first item the view holds
    expect(channel.pushed.at(-1)).toEqual({ event: "earlier", payload: { before: "u41", limit: 500 } });
    expect(screen.getByTestId("history-edge")).toHaveTextContent("正在加载");
    act(() => channel.answer("ok", { items: turnItems(21, 40), earlier: { items: 40, turns: 20, partial: 0, activities: [] } }));
    await screen.findByText("问题 21");
    expect(screen.queryByText("问题 20")).not.toBeInTheDocument();
    expect(screen.getByTestId("history-edge")).toHaveTextContent("还有 20 轮更早的对话");

    await user.click(within(screen.getByTestId("history-edge")).getByRole("button", { name: /显示全部/ }));
    expect(channel.pushed.at(-1)).toEqual({ event: "earlier", payload: { before: "u21", limit: "all" } });
    act(() => channel.answer("ok", { items: turnItems(1, 20), earlier: none }));
    await screen.findByText("问题 1");
    expect(screen.queryByTestId("history-edge")).not.toBeInTheDocument();
  });

  test("opening a conversation scrolls straight to its latest message", async () => {
    renderAt("/p/app-1/t/t1", { strict: true });
    await waitFor(() => expect(document.querySelector('[data-slot="aui_thread-viewport"]')).not.toBeNull());
    const viewport = document.querySelector<HTMLElement>('[data-slot="aui_thread-viewport"]')!;
    Object.defineProperty(viewport, "scrollHeight", { configurable: true, value: 900 });
    await waitFor(() => expect(channel.topics).toContain("thread:thr_1"));
    act(() => channel.reply("ok", { ...snapshot, items: turnItems(1, 45) }));
    await screen.findByText("回答 45");
    await waitFor(() => expect(viewport.scrollTop).toBe(900));
  });

  test("reopening a previously read conversation restores its reading position instead of jumping to the tail", async () => {
    const previous = document.createElement("div");
    Object.defineProperties(previous, { scrollHeight: { value: 2000 }, clientHeight: { value: 300 } });
    previous.scrollTop = 400;
    rememberScroll("id-1:t1", previous);
    renderAt("/p/app-1/t/t1", { strict: true });
    await waitFor(() => expect(document.querySelector('[data-slot="aui_thread-viewport"]')).not.toBeNull());
    const viewport = document.querySelector<HTMLElement>('[data-slot="aui_thread-viewport"]')!;
    Object.defineProperties(viewport, {
      scrollHeight: { configurable: true, value: 2000 },
      clientHeight: { configurable: true, value: 300 },
    });
    await waitFor(() => expect(channel.topics).toContain("thread:thr_1"));
    act(() => channel.reply("ok", { ...snapshot, items: turnItems(1, 45) }));
    await screen.findByText("回答 45");
    await waitFor(() => expect(viewport.scrollTop).toBe(400));
  });

  test("the chat viewport leaves scroll anchoring to auto-follow during streamed layout changes", async () => {
    await open();
    const viewport = document.querySelector<HTMLElement>('[data-slot="aui_thread-viewport"]')!;
    expect(viewport.className.split(" ")).toContain("[overflow-anchor:none]");
    expect(viewport).toHaveAttribute("data-slot", "aui_thread-viewport");
    expect(viewport.querySelector('[data-slot="aui_thread-content"]')).not.toBeNull();
  });

  test("a window that starts inside a turn says how much of that turn is above it", async () => {
    renderAt("/p/app-1/t/t1");
    await waitFor(() => expect(channel.topics).toContain("thread:thr_1"));
    act(() => channel.reply("ok", { ...snapshot, items: turnItems(9, 9), earlier: { items: 27, turns: 2, partial: 3, activities: [] } }));
    await screen.findByText("问题 9");
    expect(screen.getByTestId("history-edge")).toHaveTextContent("还有 2 轮更早的对话");
    expect(screen.getByTestId("history-edge")).toHaveTextContent("这一轮还有 3 条更早的内容");
    expect(within(screen.getByTestId("history-edge")).getByRole("button", { name: /显示更早 27 条/ })).toBeInTheDocument();
  });

  test("renders the snapshot: user message, command block, markdown reply", async () => {
    await open();
    expect(screen.getByTestId("tool-command")).toHaveTextContent("mix test");
    // finished commands are collapsed rows; the output is a click away
    await userEvent.click(screen.getByRole("button", { name: /运行了/ }));
    expect(screen.getByText("12 tests, 0 failures")).toBeInTheDocument();
    expect(screen.getByText("green").tagName).toBe("STRONG");
  });

  test("the composer sends a turn with the picked model", async () => {
    const user = userEvent.setup();
    await open();
    await user.click(screen.getByTestId("model-picker"));
    await user.click(await screen.findByRole("option", { name: /^glm-5/ }));
    await user.type(
      screen.getByRole("textbox", { name: "随心输入" }),
      "next step{Enter}",
    );
    await waitFor(() =>
      expect(sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          input: expect.objectContaining({
            threadId: "t1",
            text: "next step",
            model: "glm-5",
          }),
        }),
      ),
    );
  });

  test("a chrome-only macOS host keeps the web model picker and shell callbacks", async () => {
    delete window.LongxAndroid;
    delete window.webkit;
    const setChrome = vi.fn();
    window.longxNative = { setChrome };
    try {
      const user = userEvent.setup();
      vi.mocked(listModels).mockResolvedValue(
        ok([
          model(1, { slug: "deepseek-flash", default: true, reasoningLevels: ["low"], reasoningEffort: "low" }),
          model(2, { slug: "glm-5", reasoningLevels: ["low"], reasoningEffort: "low" }),
        ]) as never,
      );
      await open();
      expect(window.LongxShell).toBeDefined();
      expect(document.documentElement.getAttribute("data-shell")).toBe("macos");

      await user.click(screen.getByTestId("model-picker"));
      await user.click(await screen.findByRole("option", { name: /^glm-5/ }));
      expect(screen.getByTestId("model-picker")).toHaveTextContent("glm-5");
      expect(setChrome).toHaveBeenCalled();
    } finally {
      delete window.longxNative;
      delete window.LongxShell;
      document.documentElement.removeAttribute("data-shell");
    }
  });

  test("inside a native shell the model picker is the shell's own list: model, then its levels; the choice rides on the turn", async () => {
    const posts: Record<string, unknown>[] = [];
    window.LongxAndroid = { post: (json: string) => posts.push(JSON.parse(json)) };
    try {
      const user = userEvent.setup();
      vi.mocked(listModels).mockResolvedValue(
        ok([
          model(1, { slug: "deepseek-flash", default: true, reasoningLevels: ["low", "high", "max"], reasoningEffort: "high" }),
          model(2, { slug: "glm-5", reasoningLevels: ["low", "high"], reasoningEffort: "high" }),
        ]) as never,
      );
      await open();
      await waitFor(() => expect(window.LongxShell).toBeDefined());
      await user.click(screen.getByTestId("model-picker"));
      // no popover: a pick request instead, models grouped by provider
      expect(screen.queryByRole("option", { name: /glm-5/ })).not.toBeInTheDocument();
      const pick = posts.find((p) => p["type"] === "pick") as { id: string; title: string; sections: { label: string; options: { id: string }[] }[]; selected: string };
      expect(pick.title).toBe("模型");
      expect(pick.selected).toBe("plus");
      // the tiers and aliases first (their own section), then the models by provider
      expect(pick.sections.flatMap((s) => s.options.map((o) => o.id))).toEqual(["ultra", "pro", "plus", "deepseek-flash", "glm-5"]);
      window.LongxShell!.picked(pick.id, "glm-5");
      // the model has levels: a second list, the model's default preselected
      await waitFor(() => expect(posts.filter((p) => p["type"] === "pick")).toHaveLength(2));
      const levels = posts.filter((p) => p["type"] === "pick")[1] as { id: string; title: string; sections: { options: { id: string }[] }[]; selected: string };
      expect(levels.title).toBe("思考");
      expect(levels.selected).toBe("high");
      expect(levels.sections[0]!.options.map((o) => o.id)).toEqual(["low", "high"]);
      window.LongxShell!.picked(levels.id, "low");
      await waitFor(() => expect(screen.getByTestId("model-picker")).toHaveTextContent("glm-5"));
      await user.type(screen.getByRole("textbox", { name: "随心输入" }), "go{Enter}");
      await waitFor(() =>
        expect(sendMessage).toHaveBeenCalledWith(
          expect.objectContaining({ input: expect.objectContaining({ model: "glm-5", effort: "low" }) }),
        ),
      );
    } finally {
      delete window.LongxAndroid;
      delete window.LongxShell;
    }
  });

  test("the model picker offers the model's reasoning levels; the picked level rides on the turn and the new-chat start", async () => {
    const user = userEvent.setup();
    vi.mocked(listModels).mockResolvedValue(
      ok([
        model(1, {
          slug: "deepseek-flash",
          default: true,
          reasoningLevels: ["low", "high", "max"],
          reasoningEffort: "high",
        }),
        model(2, {
          slug: "glm-5",
          reasoningLevels: ["low", "high"],
          reasoningEffort: "high",
        }),
        model(3, { slug: "plain", reasoningEffort: null }),
      ]) as never,
    );
    const first = await open();
    // the thread runs on the default — the plus tier, standing for deepseek-flash — at that model's default level
    await waitFor(() => expect(screen.getByTestId("model-picker")).toHaveTextContent("plus"));
    expect(screen.getByTestId("model-picker")).toHaveTextContent("deepseek-flash");
    expect(screen.getByTestId("model-picker")).toHaveTextContent("high");
    await user.click(screen.getByTestId("model-picker"));
    await user.click(await screen.findByRole("radio", { name: "max" }));
    await user.keyboard("{Escape}");
    expect(screen.getByTestId("model-picker")).toHaveTextContent("max");
    await user.type(
      screen.getByRole("textbox", { name: "随心输入" }),
      "go{Enter}",
    );
    await waitFor(() =>
      expect(sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          input: expect.objectContaining({
            threadId: "t1",
            text: "go",
            effort: "max",
          }),
        }),
      ),
    );

    // a model without declared levels has no level row
    await user.click(screen.getByTestId("model-picker"));
    await user.click(await screen.findByRole("option", { name: /plain/ }));
    await user.click(screen.getByTestId("model-picker"));
    expect(screen.queryByRole("radio")).not.toBeInTheDocument();
    await user.keyboard("{Escape}");

    // a new chat starts the thread on the picked model and level
    first.unmount();
    vi.mocked(sendMessage).mockClear();
    const { router } = renderAt("/p/app-1/t/t1");
    await user.click(within(await screen.findByTestId("threads-tool")).getByRole("button", { name: /新会话/ }));
    await screen.findByText("让 agent 在这个项目里干活");
    await user.click(screen.getByTestId("model-picker"));
    await user.click(await screen.findByRole("option", { name: /^glm-5/ }));
    // switching models lands on the new model's default level
    expect(screen.getByTestId("model-picker")).toHaveTextContent(/glm-5\s*high/);
    await user.click(screen.getByTestId("model-picker"));
    await user.click(await screen.findByRole("radio", { name: "low" }));
    await user.keyboard("{Escape}");
    await user.type(
      screen.getByRole("textbox", { name: "随心输入" }),
      "start low{Enter}",
    );
    await waitFor(() =>
      expect(startThread).toHaveBeenCalledWith(
        expect.objectContaining({
          input: expect.objectContaining({
            projectId: "id-1",
            model: "glm-5",
            effort: "low",
          }),
        }),
      ),
    );
    await waitFor(() =>
      expect(router.state.location.pathname).toBe("/p/app-1/t/t2"),
    );
  });

  test("live events stream in: a running command opens its row, the composer offers stop", async () => {
    await open();
    act(() => {
      channel.deliver("event", {
        seq: 4,
        method: "turn/started",
        params: { turn: { id: "turn_2", status: "inProgress" } },
      });
      channel.deliver("event", {
        seq: 5,
        method: "item/started",
        params: {
          turnId: "turn_2",
          item: {
            id: "c2",
            type: "commandExecution",
            command: "rm -rf build",
            cwd: "/p",
            status: "inProgress",
          },
        },
      });
      channel.deliver("event", { seq: 6, method: "item/commandExecution/outputDelta", params: { itemId: "c2", delta: "removing…\n" } });
    });
    expect(screen.getByTestId("turn-bar")).toHaveTextContent("进行中");
    expect(screen.getByText("removing…")).toBeInTheDocument();
    // the composer offers stop while the turn runs
    expect(screen.getByRole("button", { name: /停止/ })).toBeInTheDocument();
  });

  test("the turn bar says what the model is writing — a call's arguments, bytes so far — and a retry after a broken stream", async () => {
    await open();
    act(() => {
      channel.deliver("event", { seq: 4, method: "turn/started", params: { turn: { id: "turn_2", status: "inProgress" } } });
      channel.deliver("event", { seq: 5, method: "turn/progress", params: { turnId: "turn_2", progress: { kind: "toolCall", name: "apply_patch", bytes: 12_800 } } });
    });
    const bar = screen.getByTestId("turn-bar");
    expect(bar).toHaveTextContent("正在写 apply_patch 的参数");
    expect(bar).toHaveTextContent("13 KB");
    act(() => {
      channel.deliver("event", { seq: 6, method: "turn/progress", params: { turnId: "turn_2", progress: { kind: "retry", name: "the stream broke", bytes: 0 } } });
    });
    expect(bar).toHaveTextContent("正在重试");
    expect(bar).not.toHaveTextContent("the stream broke");
    act(() => {
      channel.deliver("event", { seq: 7, method: "turn/progress", params: { turnId: "turn_2", progress: null } });
    });
    expect(bar).toHaveTextContent("进行中");
    expect(bar).not.toHaveTextContent("重试");
  });

  // the ChatGPT backend once stopped mid-call with the connection open: the bar said
  // 正在写 apply_patch 的参数（255 B） for ten minutes, as if Longx hung
  test("the turn bar says when the upstream has sent nothing for a while — on the call being written, or as a wait on the model", async () => {
    await open();
    act(() => {
      channel.deliver("event", { seq: 4, method: "turn/started", params: { turn: { id: "turn_2", status: "inProgress" } } });
      channel.deliver("event", { seq: 5, method: "turn/progress", params: { turnId: "turn_2", progress: { kind: "toolCall", name: "apply_patch", bytes: 255, quiet: 45 } } });
    });
    const bar = screen.getByTestId("turn-bar");
    expect(bar).toHaveTextContent("正在写 apply_patch 的参数");
    expect(bar).toHaveTextContent("上游 45 秒没有数据");
    act(() => {
      channel.deliver("event", { seq: 6, method: "turn/progress", params: { turnId: "turn_2", progress: { kind: "toolCall", name: "apply_patch", bytes: 300 } } });
    });
    expect(bar).not.toHaveTextContent("没有数据");
    act(() => {
      channel.deliver("event", { seq: 7, method: "turn/progress", params: { turnId: "turn_2", progress: { kind: "waiting", name: "gpt-6-luna", bytes: 0, quiet: 90 } } });
    });
    expect(bar).toHaveTextContent("等 gpt-6-luna 回应");
    expect(bar).toHaveTextContent("上游 90 秒没有数据");
  });

  test("the turn bar shows a context fold while it runs — between turns too, where no turn spins — and clears when it is over", async () => {
    await open();
    // /compact between turns: no turn/started, only the kernel's progress
    act(() => {
      channel.deliver("event", { seq: 4, method: "turn/progress", params: { turnId: null, progress: { kind: "compaction", name: "plus", bytes: 0 } } });
    });
    const bar = screen.getByTestId("turn-bar");
    expect(bar).toHaveTextContent("正在压缩上下文");
    act(() => {
      channel.deliver("event", { seq: 5, method: "turn/progress", params: { turnId: null, progress: { kind: "compaction", name: "plus", bytes: 2048 } } });
    });
    expect(bar).toHaveTextContent("2.0 KB");
    act(() => {
      channel.deliver("event", { seq: 6, method: "turn/progress", params: { turnId: null, progress: null } });
    });
    expect(bar).toHaveTextContent("");
    // mid-turn (the context passed the threshold): the same words in place of 进行中
    act(() => {
      channel.deliver("event", { seq: 7, method: "turn/started", params: { turn: { id: "turn_2", status: "inProgress" } } });
      channel.deliver("event", { seq: 8, method: "turn/progress", params: { turnId: "turn_2", progress: { kind: "compaction", name: "plus", bytes: 0 } } });
    });
    expect(bar).toHaveTextContent("正在压缩上下文");
    act(() => {
      channel.deliver("event", { seq: 9, method: "turn/progress", params: { turnId: "turn_2", progress: null } });
    });
    expect(bar).toHaveTextContent("进行中");
  });

  test("a turn that failed because its model gave up offers another model to go on with: the choice sends 继续 on it", async () => {
    const user = userEvent.setup();
    await open();
    act(() => {
      channel.deliver("event", { seq: 4, method: "turn/started", params: { turn: { id: "turn_2", status: "inProgress" } } });
      channel.deliver("event", {
        seq: 5,
        method: "turn/completed",
        params: { turn: { id: "turn_2", status: "failed", error: { message: "model deepseek-flash failed: the stream broke", code: "model_failed", model: "deepseek-flash", httpStatus: 503, source: "http" } } },
      });
    });
    await user.click(await screen.findByRole("button", { name: "查看错误" }));
    const banner = await screen.findByTestId("request-error-details");
    expect(banner).toHaveTextContent("HTTP 503");
    expect(banner).toHaveTextContent("deepseek-flash");
    expect(banner).toHaveTextContent("the stream broke");
    await user.click(within(banner).getByRole("combobox"));
    await user.click(await screen.findByRole("option", { name: /glm-5/ }));
    await user.click(within(banner).getByRole("button", { name: "换个模型继续" }));
    await waitFor(() =>
      expect(sendMessage).toHaveBeenCalledWith(expect.objectContaining({ input: expect.objectContaining({ threadId: "t1", text: "继续", model: "glm-5" }) })),
    );
  });

  test("retry status stays short while error details show and copy the real HTTP 200 stream failure", async () => {
    const user = userEvent.setup();
    await open();
    const message = "the model failed: An error occurred while processing your request. Request ID 0ca6ca65-fd98-49c6-ac38-7dea5ec484f1";
    act(() => {
      channel.deliver("event", { seq: 4, method: "turn/started", params: { turn: { id: "turn_2", status: "inProgress" } } });
      channel.deliver("event", { seq: 5, method: "turn/progress", params: { turnId: "turn_2", progress: {
        kind: "retry", name: message, bytes: 0, httpStatus: 200, source: "stream", attempt: 1, limit: 3,
      } } });
    });
    const rail = screen.getByTestId("turn-bar");
    expect(rail).toHaveTextContent("正在重试");
    expect(rail).not.toHaveTextContent(message);
    expect(within(rail).queryByRole("button", { name: "查看错误" })).not.toBeInTheDocument();
    expect(screen.queryByText(message)).not.toBeInTheDocument();
    await user.click(within(screen.getByTestId("status-strip")).getByRole("button", { name: "查看错误" }));
    const details = await screen.findByTestId("request-error-details");
    expect(details).toHaveTextContent("HTTP 200");
    expect(details).toHaveTextContent("响应流内错误");
    expect(details).toHaveTextContent(message);
    const writeText = vi.fn().mockResolvedValue(undefined);
    Object.defineProperty(navigator, "clipboard", { value: { writeText }, configurable: true });
    await user.click(within(details).getByRole("button", { name: "复制错误信息" }));
    expect(writeText).toHaveBeenCalledWith(expect.stringContaining("HTTP 200"));
    expect(writeText).toHaveBeenCalledWith(expect.stringContaining(message));
    expect(sendMessage).not.toHaveBeenCalled();
    await user.keyboard("{Escape}");
    act(() => channel.deliver("event", { seq: 6, method: "turn/progress", params: { turnId: "turn_2", progress: null } }));
    await waitFor(() => expect(screen.queryByTestId("request-error-status")).not.toBeInTheDocument());
  });

  test("legacy or transport errors never infer a status code from the error text", async () => {
    const user = userEvent.setup();
    await open();
    act(() => channel.deliver("event", { seq: 4, method: "turn/completed", params: { turn: {
      id: "turn_1", status: "failed", error: { code: "model_failed", message: "connection failed before HTTP response; text mentions 502", httpStatus: null, source: "transport" },
    } } }));
    await user.click(await screen.findByRole("button", { name: "查看错误" }));
    const details = await screen.findByTestId("request-error-details");
    expect(details).toHaveTextContent("未记录／未获得 HTTP 响应");
    expect(details).toHaveTextContent("连接／传输错误");
    expect(details).not.toHaveTextContent("HTTP 502");
  });

  test("a new turn closes old error details and never reuses a prior compaction failure", async () => {
    const user = userEvent.setup();
    await open();
    act(() => channel.deliver("event", { seq: 4, method: "item/completed", params: { item: {
      id: "cf-old", type: "contextCompactionFailed", turnId: "turn_1",
      error: "old compaction error", httpStatus: 200, source: "stream",
    } } }));
    await user.click(await screen.findByRole("button", { name: "查看错误" }));
    expect(await screen.findByTestId("request-error-details")).toHaveTextContent("old compaction error");
    act(() => channel.deliver("event", { seq: 5, method: "turn/started", params: { turn: { id: "turn_2", status: "inProgress" } } }));
    await waitFor(() => expect(screen.queryByTestId("request-error-details")).not.toBeInTheDocument());
    act(() => channel.deliver("event", { seq: 6, method: "turn/completed", params: { turn: {
      id: "turn_2", status: "failed", error: { code: "model_failed", message: "new gateway error", httpStatus: 502, source: "http" },
    } } }));
    expect(screen.queryByTestId("request-error-details")).not.toBeInTheDocument();
    await user.click(await screen.findByRole("button", { name: "查看错误" }));
    const details = await screen.findByTestId("request-error-details");
    expect(details).toHaveTextContent("HTTP 502");
    expect(details).toHaveTextContent("new gateway error");
    expect(details).not.toHaveTextContent("old compaction error");
  });

  test("Escape in the composer never stops the turn: an IME user presses it all the time; stop is the button", async () => {
    const user = userEvent.setup();
    await open();
    act(() => {
      channel.deliver("event", { seq: 4, method: "turn/started", params: { turn: { id: "turn_2", status: "inProgress" } } });
      channel.deliver("event", {
        seq: 5,
        method: "item/started",
        params: { turnId: "turn_2", item: { id: "c2", type: "commandExecution", command: "sleep 45", cwd: "/p", status: "inProgress" } },
      });
    });
    expect(screen.getByRole("button", { name: /停止/ })).toBeInTheDocument();
    await user.click(screen.getByRole("textbox", { name: "随心输入" }));
    await user.keyboard("{Escape}");
    await new Promise((r) => setTimeout(r, 50));
    expect(interruptTurn).not.toHaveBeenCalled();
    expect(retractTurn).not.toHaveBeenCalled();
    expect(screen.getByTestId("turn-bar")).toHaveTextContent("进行中");
  });

  test("all waiting callbacks insert with one RPC, block double clicks, and survive an RPC failure", async () => {
    const user = userEvent.setup();
    await open();
    act(() => channel.deliver("event", {
      seq: 4, method: "thread/waiting/updated", params: {
        waiting: [
          { id: "w1", text: "first", from: "coder", at: "2026-10-05T00:00:00Z" },
          { id: "w2", text: "final", from: "coder", at: "2026-10-05T00:00:01Z" },
        ], paused: false,
      },
    }));
    let finish!: (value: never) => void;
    vi.mocked(releaseWaitingBatch).mockImplementationOnce(() => new Promise(resolve => { finish = resolve; }));
    const button = await screen.findByRole("button", { name: "全部插入" });
    await user.click(button);
    await user.click(button);
    expect(button).toBeDisabled();
    expect(releaseWaitingBatch).toHaveBeenCalledExactlyOnceWith(expect.objectContaining({ input: { threadId: "t1" } }));
    expect(releaseWaiting).not.toHaveBeenCalled();
    await act(async () => finish(failed("offline") as never));
    expect(await screen.findByRole("button", { name: /待处理消息 · 2 条/ })).toHaveAttribute("aria-expanded", "false");
    expect(button).not.toBeDisabled();
    expect(toast.error).toHaveBeenCalled();
    await user.click(button);
    expect(releaseWaitingBatch).toHaveBeenCalledTimes(2);
  });

  test("a stop before the model answers takes the message back into the composer, before what was being typed; what arrives from elsewhere waits above the composer with 立即插入", async () => {
    const user = userEvent.setup();
    await open();
    act(() => {
      channel.deliver("event", { seq: 4, method: "turn/started", params: { turn: { id: "turn_2", status: "inProgress" } } });
      channel.deliver("event", {
        seq: 5,
        method: "item/completed",
        params: { turnId: "turn_2", item: { id: "u2", type: "userMessage", turnId: "turn_2", content: [{ type: "text", text: "look at pandas" }] } },
      });
      // thinking is no answer
      channel.deliver("event", {
        seq: 6,
        method: "item/completed",
        params: { turnId: "turn_2", item: { id: "r2", type: "reasoning", turnId: "turn_2", summary: ["let me see"] } },
      });
      channel.deliver("event", {
        seq: 7,
        method: "thread/waiting/updated",
        params: { waiting: [{ id: "w1", text: "tests pass", from: "coder", kind: "report", at: "2026-09-25T01:00:00Z" }], paused: false },
      });
    });

    // a report while the turn runs: its own row, not the composer
    await user.click(await screen.findByRole("button", { name: /待处理消息/ }));
    const row = await screen.findByTestId("waiting-message");
    expect(row).toHaveTextContent("coder · 汇报");
    const composer = screen.getByRole("textbox", { name: "随心输入" });
    expect(composer).toHaveValue("");
    await user.click(within(row).getByRole("button", { name: /立即插入/ }));
    await waitFor(() => expect(releaseWaiting).toHaveBeenCalledWith(expect.objectContaining({ input: { threadId: "t1", waitingId: "w1" } })));

    // a draft typed: the stop button gives way to send, so the stop is Esc Esc (the keys)
    await user.type(composer, "and koalas");
    vi.mocked(retractTurn).mockResolvedValueOnce(ok({ text: "look at pandas" }) as never);
    await waitFor(() => expect(commands.available("turn.stop")).toBe(true));
    await user.keyboard("{Escape}");
    await user.keyboard("{Escape}");
    await waitFor(() => expect(retractTurn).toHaveBeenCalledWith(expect.objectContaining({ input: { threadId: "t1", kernelTurnId: "turn_2" } })));
    expect(interruptTurn).not.toHaveBeenCalled();
    // the message is back for editing, ahead of what was being typed
    await waitFor(() => expect(composer).toHaveValue("look at pandas\n\nand koalas"));
    act(() => {
      channel.deliver("event", { seq: 8, method: "thread/reverted", params: { turnIds: ["turn_2"] } });
    });
    expect(screen.queryByTestId("stopped-turn")).not.toBeInTheDocument();
  });

  test("a stop after the model answered only interrupts: the stopped turn says so, with 继续 and 丢弃, and the composer is left alone", async () => {
    vi.mocked(retractTurn).mockClear();
    vi.mocked(interruptTurn).mockClear();
    const user = userEvent.setup();
    await open();
    act(() => {
      channel.deliver("event", { seq: 4, method: "turn/started", params: { turn: { id: "turn_2", status: "inProgress" } } });
      channel.deliver("event", {
        seq: 5,
        method: "item/completed",
        params: { turnId: "turn_2", item: { id: "u2", type: "userMessage", turnId: "turn_2", content: [{ type: "text", text: "look at pandas" }] } },
      });
      channel.deliver("event", {
        seq: 6,
        method: "item/started",
        params: { turnId: "turn_2", item: { id: "a2", type: "agentMessage", turnId: "turn_2", text: "Pandas are" } },
      });
    });
    const composer = screen.getByRole("textbox", { name: "随心输入" });
    await user.click(await screen.findByRole("button", { name: /停止/ }));
    await waitFor(() => expect(interruptTurn).toHaveBeenCalledWith(expect.objectContaining({ input: { threadId: "t1", kernelTurnId: "turn_2" } })));
    expect(retractTurn).not.toHaveBeenCalled();
    expect(composer).toHaveValue("");

    act(() => {
      channel.deliver("event", {
        seq: 7,
        method: "turn/completed",
        params: { turn: { id: "turn_2", status: "interrupted", error: { message: "stopped by the person from the page", by: "person" } } },
      });
    });
    const card = await screen.findByTestId("stopped-turn");
    expect(card).toHaveTextContent("你停止了这一轮");
    await user.click(within(card).getByRole("button", { name: "丢弃" }));
    await waitFor(() => expect(retractTurn).toHaveBeenCalledWith(expect.objectContaining({ input: { threadId: "t1", kernelTurnId: "turn_2" } })));
    expect(composer).toHaveValue("");
    await user.click(within(card).getByRole("button", { name: /继续/ }));
    await waitFor(() => expect(sendMessage).toHaveBeenCalledWith(expect.objectContaining({ input: expect.objectContaining({ threadId: "t1", text: "继续" }) })));
  });

  test("the top bar copies this conversation's API address (its JSON for another agent)", async () => {
    // after setup: user-event installs a clipboard of its own
    const user = userEvent.setup();
    const writeText = vi.fn(async () => {});
    Object.defineProperty(navigator, "clipboard", { value: { writeText }, configurable: true });
    await open();
    await user.click(screen.getByRole("button", { name: "复制 API 地址" }));
    await waitFor(() => expect(writeText).toHaveBeenCalledWith(`${window.location.origin}/api/p/app-1/t/t1`));
    expect(toast.success).toHaveBeenCalledWith("已复制 API 地址", expect.anything());
    Object.defineProperty(navigator, "clipboard", { value: undefined, configurable: true });
  });

  test("the column follows ChatGPT's: 40rem, 48rem once the chat area is 56rem wide; the margins outside it 1 / 1.5 / 4rem — the chat area's width, not the screen's", async () => {
    await open();
    const viewport = document.querySelector('[data-slot="aui_thread-viewport"]')!;
    for (const token of [
      "px-(--thread-margin)",
      "[--thread-margin:1rem]",
      "@min-[40rem]:[--thread-margin:1.5rem]",
      "@min-[56rem]:[--thread-margin:4rem]",
      "[--thread-max-width:40rem]",
      "@min-[56rem]:[--thread-max-width:48rem]",
    ])
      expect(viewport.className.split(" ")).toContain(token);
    // the margin is outside the column: the column itself has none
    const column = viewport.firstElementChild!;
    expect(column.className).toContain("max-w-(--thread-max-width)");
    expect(column.className.split(" ")).not.toContain("px-4");
    // the text shares the composer's left edge, as ChatGPT's does: no inset of its own
    const content = await screen.findAllByText((_, el) => el?.getAttribute("data-slot") === "aui_assistant-message-content");
    for (const el of content) expect(el.className.split(" ")).not.toContain("px-2");
  });

  test("an unrecoverable thread cannot take messages", async () => {
    vi.mocked(listThreads).mockResolvedValueOnce({
      success: true,
      data: [
        {
          id: "t1",
          kernelThreadId: "thr_1",
          title: null,
          preview: "x",
          status: "unrecoverable",
          modelSlug: null,
          lastActivityAt: null,
          insertedAt: "2026-09-12T00:00:00Z",
        },
      ],
    } as never);
    await open();
    expect(screen.getByRole("alert")).toHaveTextContent("已无法恢复");
    expect(screen.getByRole("textbox", { name: "随心输入" })).toBeDisabled();
  });

  test("the project route is a new chat: the first message creates the thread (with the project's web search) and opens it", async () => {
    const user = userEvent.setup();
    const { router } = renderAt("/p/app-1");
    await screen.findByText("让 agent 在这个项目里干活");
    expect(channel.topics.filter((t) => t.startsWith("thread:"))).toEqual([]);
    // no conversation yet: no API address to copy
    expect(screen.queryByRole("button", { name: "复制 API 地址" })).toBeNull();
    // no access mode to pick: the kernel runs as the person
    expect(screen.queryByTestId("mode-picker")).not.toBeInTheDocument();
    await user.type(
      screen.getByRole("textbox", { name: "随心输入" }),
      "start here{Enter}",
    );
    await waitFor(() =>
      expect(startThread).toHaveBeenCalledWith(
        expect.objectContaining({
          input: expect.objectContaining({
            projectId: "id-1",
            webSearch: true,
          }),
        }),
      ),
    );
    await waitFor(() =>
      expect(sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          input: expect.objectContaining({
            threadId: "t2",
            text: "start here",
          }),
        }),
      ),
    );
    await waitFor(() =>
      expect(router.state.location.pathname).toBe("/p/app-1/t/t2"),
    );
  });

  test("the goal sits above the thread: objective, status, budget; pause / resume / clear; edited in a dialog; /goal opens it", async () => {
    const user = userEvent.setup();
    await open();
    expect(screen.queryByTestId("goal-bar")).not.toBeInTheDocument();
    act(() => {
      channel.deliver("event", {
        seq: 4,
        method: "thread/goal/updated",
        params: { threadId: "thr_1", turnId: null, goal: { threadId: "thr_1", objective: "让测试全绿", status: "active", tokenBudget: 50000, tokensUsed: 12500, timeUsedSeconds: 125, createdAt: 1, updatedAt: 2 } },
      });
    });
    let bar = await screen.findByTestId("goal-bar");
    expect(bar).toHaveTextContent("让测试全绿");
    expect(bar).toHaveTextContent("进行中");
    expect(bar).toHaveTextContent("12.5k / 50k");
    expect(bar).toHaveTextContent("2 分钟");

    await user.click(within(bar).getByRole("button", { name: "暂停" }));
    await waitFor(() => expect(setGoal).toHaveBeenCalledWith(expect.objectContaining({ input: { threadId: "t1", status: "paused" } })));

    act(() => {
      channel.deliver("event", {
        seq: 5,
        method: "thread/goal/updated",
        params: { threadId: "thr_1", turnId: null, goal: { threadId: "thr_1", objective: "让测试全绿", status: "paused", tokenBudget: 50000, tokensUsed: 12500, timeUsedSeconds: 125, createdAt: 1, updatedAt: 2 } },
      });
    });
    await waitFor(() => expect(bar).toHaveTextContent("已暂停"));

    // blocked says why: the plug's cap on rounds, the budget, or the model's own sentence
    act(() => {
      channel.deliver("event", {
        seq: 6,
        method: "thread/goal/updated",
        params: { threadId: "thr_1", turnId: null, goal: { threadId: "thr_1", objective: "让测试全绿", status: "blocked", reason: "rounds", tokenBudget: 50000, tokensUsed: 12500, timeUsedSeconds: 125, createdAt: 1, updatedAt: 2 } },
      });
    });
    await waitFor(() => expect(bar).toHaveTextContent("卡住了"));
    expect(bar).toHaveTextContent("一个回合里连跑了太多轮");
    act(() => {
      channel.deliver("event", {
        seq: 7,
        method: "thread/goal/updated",
        params: { threadId: "thr_1", turnId: null, goal: { threadId: "thr_1", objective: "让测试全绿", status: "blocked", reason: "需要 COROS 的登录", tokenBudget: 50000, tokensUsed: 12500, timeUsedSeconds: 125, createdAt: 1, updatedAt: 2 } },
      });
    });
    await waitFor(() => expect(bar).toHaveTextContent("需要 COROS 的登录"));
    // done: the bar leaves (a finished goal stayed above every later message)
    act(() => {
      channel.deliver("event", {
        seq: 8,
        method: "thread/goal/updated",
        params: { threadId: "thr_1", turnId: null, goal: { threadId: "thr_1", objective: "让测试全绿", status: "complete", tokenBudget: 50000, tokensUsed: 12500, timeUsedSeconds: 125, createdAt: 1, updatedAt: 2 } },
      });
    });
    await waitFor(() => expect(screen.queryByTestId("goal-bar")).not.toBeInTheDocument());
    act(() => {
      channel.deliver("event", {
        seq: 9,
        method: "thread/goal/updated",
        params: { threadId: "thr_1", turnId: null, goal: { threadId: "thr_1", objective: "让测试全绿", status: "blocked", reason: "需要 COROS 的登录", tokenBudget: 50000, tokensUsed: 12500, timeUsedSeconds: 125, createdAt: 1, updatedAt: 2 } },
      });
    });
    bar = await screen.findByTestId("goal-bar");
    await user.click(within(bar).getByRole("button", { name: "继续" }));
    await waitFor(() => expect(setGoal).toHaveBeenLastCalledWith(expect.objectContaining({ input: { threadId: "t1", status: "active" } })));

    // the dialog edits objective and budget
    await user.click(within(bar).getByRole("button", { name: "编辑" }));
    const dialog = await screen.findByRole("dialog");
    const objective = within(dialog).getByLabelText("目标");
    expect(objective).toHaveValue("让测试全绿");
    await user.clear(objective);
    await user.type(objective, "跑通回测");
    await user.clear(within(dialog).getByLabelText(/token 预算/));
    await user.type(within(dialog).getByLabelText(/token 预算/), "80000");
    await user.click(within(dialog).getByRole("button", { name: "保存" }));
    // saved while blocked: the goal goes active again with the new words
    await waitFor(() => expect(setGoal).toHaveBeenLastCalledWith(expect.objectContaining({ input: { threadId: "t1", objective: "跑通回测", tokenBudget: 80000, status: "active" } })));

    await user.click(within(bar).getByRole("button", { name: "清除" }));
    await waitFor(() => expect(clearGoal).toHaveBeenCalledWith(expect.objectContaining({ input: { threadId: "t1" } })));
    act(() => channel.deliver("event", { seq: 10, method: "thread/goal/cleared", params: { threadId: "thr_1" } }));
    await waitFor(() => expect(screen.queryByTestId("goal-bar")).not.toBeInTheDocument());

    // /goal opens the dialog for a new goal
    await user.type(screen.getByRole("textbox", { name: "随心输入" }), "/goal");
    await user.click(await screen.findByRole("option", { name: /goal/ }));
    const fresh = await screen.findByRole("dialog");
    expect(within(fresh).getByLabelText("目标")).toHaveValue("");
  });

  test("the kernel falling back to another model of the chain mid-turn is said in a toast", async () => {
    await open();
    act(() => {
      channel.deliver("event", {
        seq: 4,
        method: "model/rerouted",
        params: { threadId: "thr_1", turnId: "turn_1", fromModel: "a", toModel: "b", reason: "quota" },
      });
    });
    await waitFor(() => expect(toast.warning).toHaveBeenCalledWith(expect.stringMatching(/模型已切换.*a.*b/), expect.anything()));
  });

  test("a disconnected thread keeps the input usable but cannot send", async () => {
    vi.mocked(listThreads).mockResolvedValue({
      success: true,
      data: [
        {
          id: "t1",
          kernelThreadId: "thr_1",
          title: null,
          preview: "x",
          status: "disconnected",
          modelSlug: null,
          lastActivityAt: null,
          insertedAt: "2026-09-12T00:00:00Z",
        },
      ],
    } as never);
    await open();
    expect(screen.getByRole("alert")).toHaveTextContent("连接断开了");
    const box = screen.getByRole("textbox", { name: "随心输入" });
    expect(box).toBeEnabled();
    expect(screen.getByRole("button", { name: "发送" })).toBeDisabled();
  });

  test("a finished turn shows its timing; a revert re-pulls the snapshot", async () => {
    await open();
    // the snapshot's turn carries the kernel's epoch-second stamps
    expect(
      screen.queryByRole("button", { name: "这一轮的耗时" }),
    ).not.toBeInTheDocument();
    act(() =>
      channel.reply("ok", {
        ...snapshot,
        seq: 4,
        turn: {
          id: "turn_1",
          status: "completed",
          startedAt: 1_700_000_000,
          completedAt: 1_700_000_007,
          usage: { inputTokens: 56_500, cachedInputTokens: 11_300, outputTokens: 628, reasoningOutputTokens: 279, totalTokens: 57_128 },
        },
      }),
    );
    const badge = await screen.findByRole("button", { name: "这一轮的耗时" });
    expect(badge).toHaveTextContent("7");
    // the turn's tokens on the badge, the breakdown a hover away
    expect(badge).toHaveTextContent("57.1k");
    await userEvent.hover(badge);
    const popover = await screen.findByRole("tooltip");
    expect(popover).toHaveTextContent("输入");
    expect(popover).toHaveTextContent("56.5k");
    expect(popover).toHaveTextContent("缓存命中");
    expect(popover).toHaveTextContent("11.3k");
    expect(popover).toHaveTextContent("思考");
    expect(popover).toHaveTextContent("279");

    act(() =>
      channel.deliver("event", {
        seq: 5,
        method: "thread/reverted",
        params: { threadId: "thr_1", turnIds: ["turn_1"] },
      }),
    );
    await waitFor(() =>
      expect(channel.pushed.at(-1)).toMatchObject({ event: "snapshot" }),
    );
  });

  test("a message typed while a turn runs is queued above the composer: inserted into the turn now, or sent when it ends", async () => {
    const user = userEvent.setup();
    await open();
    act(() =>
      channel.deliver("event", {
        seq: 4,
        method: "turn/started",
        params: { turn: { id: "turn_2", status: "inProgress" } },
      }),
    );
    // one button: stop while the draft is empty, send (into the queue) once there is text
    expect(screen.queryByRole("button", { name: "发送" })).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: /停止/ })).toBeInTheDocument();
    const input = screen.getByRole("textbox", { name: "随心输入" });
    await user.type(input, "and then this");
    expect(screen.getByRole("button", { name: "加入队列" })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /停止/ })).not.toBeInTheDocument();
    await user.type(input, "{Enter}");
    const queue = await screen.findByTestId("message-queue");
    expect(queue).toHaveTextContent("and then this");
    expect(steerTurn).not.toHaveBeenCalled();
    expect(sendMessage).not.toHaveBeenCalled();
    // 插入: into the running turn now (turn/steer), off the queue
    await user.click(within(queue).getByRole("button", { name: "插入" }));
    await waitFor(() =>
      expect(steerTurn).toHaveBeenCalledWith(
        expect.objectContaining({ input: expect.objectContaining({ threadId: "t1", text: "and then this" }) }),
      ),
    );
    await waitFor(() => expect(screen.queryByTestId("message-queue")).not.toBeInTheDocument());
    // a second one waits; 取消 takes it back; a third goes out as a new turn when the turn ends
    await user.type(input, "never mind{Enter}");
    await user.click(within(await screen.findByTestId("message-queue")).getByRole("button", { name: "取消" }));
    await waitFor(() => expect(screen.queryByTestId("message-queue")).not.toBeInTheDocument());
    await user.type(input, "later{Enter}");
    expect(await screen.findByTestId("message-queue")).toHaveTextContent("later");
    act(() =>
      channel.deliver("event", {
        seq: 5,
        method: "turn/completed",
        params: { turn: { id: "turn_2", status: "completed" } },
      }),
    );
    await waitFor(() =>
      expect(sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({ input: expect.objectContaining({ threadId: "t1", text: "later" }) }),
      ),
    );
    expect(steerTurn).toHaveBeenCalledTimes(1);
  });

  test("after a stop the queue holds its messages; 插入 then sends one as a new turn instead of into the dead turn", async () => {
    const user = userEvent.setup();
    await open();
    act(() => channel.deliver("event", { seq: 4, method: "turn/started", params: { turn: { id: "turn_2", status: "inProgress" } } }));
    act(() =>
      channel.deliver("event", {
        seq: 5,
        method: "item/started",
        params: { turnId: "turn_2", item: { id: "c2", type: "commandExecution", command: "sleep 30", cwd: "/p", status: "inProgress" } },
      }),
    );
    const input = screen.getByRole("textbox", { name: "随心输入" });
    await user.type(input, "and then this{Enter}");
    expect(await screen.findByTestId("message-queue")).toHaveTextContent("and then this");
    // stop: the turn ends interrupted; assistant-ui pauses the queue, the message stays
    await user.click(screen.getByRole("button", { name: /停止/ }));
    await waitFor(() => expect(interruptTurn).toHaveBeenCalled());
    act(() => channel.deliver("event", { seq: 6, method: "turn/completed", params: { turn: { id: "turn_2", status: "interrupted" } } }));
    expect(screen.getByTestId("message-queue")).toHaveTextContent("and then this");
    expect(sendMessage).not.toHaveBeenCalled();
    // 插入 on a turn that is over: not_running from the server, so it goes out as a new turn
    vi.mocked(steerTurn).mockResolvedValueOnce(failed("not_running", ["threadId"]) as never);
    await user.click(within(screen.getByTestId("message-queue")).getByRole("button", { name: "插入" }));
    await waitFor(() =>
      expect(sendMessage).toHaveBeenCalledWith(expect.objectContaining({ input: expect.objectContaining({ threadId: "t1", text: "and then this" }) })),
    );
    await waitFor(() => expect(screen.queryByTestId("message-queue")).not.toBeInTheDocument());
  });

  test("LaTeX in a reply is drawn by KaTeX: $…$ inline, $$…$$ display, and the \\(…\\) / \\[…\\] delimiters models emit; a price is not math", async () => {
    await open();
    act(() =>
      channel.deliver("event", {
        seq: 4,
        method: "item/completed",
        params: {
          turnId: "turn_2",
          item: { id: "m9", type: "agentMessage", turnId: "turn_2", text: "夏普 $S = \\frac{R_p - R_f}{\\sigma_p}$ 与 \\(\\alpha\\)。\n\n$$\\text{IC} = \\rho(f, r)$$\n\n\\[\\beta = 1\\]\n\n费用 $5 到 $7。" },
        },
      }),
    );
    // the renderer is a lazy chunk (KaTeX and its stylesheet): until it is in, the TeX shows as text
    await waitFor(() => expect(document.querySelectorAll(".katex").length).toBe(4), { timeout: 15_000 });
    // two inline, two display
    expect(document.querySelectorAll(".katex-display").length).toBe(2);
    expect(screen.getByText(/费用 \$5 到 \$7/)).toBeInTheDocument();
  });

  test("another agent's message is not a bubble of the person's: its name as a label, its markdown rendered", async () => {
    await open();
    act(() =>
      channel.deliver("event", {
        seq: 4,
        method: "item/completed",
        params: {
          turnId: "turn_2",
          item: { id: "u9", type: "userMessage", turnId: "turn_2", from: "researcher", content: [{ type: "text", text: "[agent researcher] **冒烟测试通过**\n\n- 未做研究\n- 未写报告" }] },
        },
      }),
    );
    const message = await screen.findByTestId("agent-message");
    expect(within(message).getByText("researcher")).toBeInTheDocument();
    expect(within(message).getByText("冒烟测试通过").tagName).toBe("STRONG");
    expect(within(message).getAllByRole("listitem")).toHaveLength(2);
    expect(message).not.toHaveTextContent("[agent researcher]");
    // an item without the kernel's kind (older transcripts) carries no detail
    expect(within(message).queryByTestId("agent-message-kind")).not.toBeInTheDocument();
  });

  test("an agent's message says what it is (a report, a question, an answer); consecutive ones from the same agent share one label", async () => {
    await open();
    const item = (id: string, kind: string, text: string) => ({
      id,
      type: "userMessage",
      turnId: "turn_2",
      from: "coder-3",
      kind,
      content: [{ type: "text", text: `[agent coder-3] ${text}` }],
    });
    act(() => {
      channel.deliver("event", { seq: 4, method: "item/completed", params: { turnId: "turn_2", item: item("u9", "report", "第一条") } });
      channel.deliver("event", { seq: 5, method: "item/completed", params: { turnId: "turn_2", item: item("u10", "report", "第二条") } });
      channel.deliver("event", { seq: 6, method: "item/completed", params: { turnId: "turn_2", item: item("u11", "answer", "回你的话") } });
    });
    await waitFor(() => expect(screen.getAllByTestId("agent-message")).toHaveLength(2));
    const [grouped, answer] = screen.getAllByTestId("agent-message");
    expect(within(grouped!).getByTestId("agent-message-kind")).toHaveTextContent("汇报 · 2 条");
    expect(grouped).toHaveTextContent("第一条");
    expect(grouped).toHaveTextContent("第二条");
    expect(within(answer!).getByTestId("agent-message-kind")).toHaveTextContent("回复");
    expect(answer).toHaveTextContent("回你的话");
  });

  test("a message from another session (an address, not a team name) is labelled with that session's title and links to it", async () => {
    vi.mocked(directory).mockResolvedValue(ok({ sessions: [session(7, { address: "~052ca4", title: "coder 定义流" }), session(2)] }) as never);
    try {
      await open();
      act(() =>
        channel.deliver("event", {
          seq: 4,
          method: "item/completed",
          params: {
            turnId: "turn_2",
            item: { id: "u9", type: "userMessage", turnId: "turn_2", from: "~052ca4", content: [{ type: "text", text: "[agent ~052ca4] 回报：不是我建的" }] },
          },
        }),
      );
      const message = await screen.findByTestId("agent-message");
      const label = await within(message).findByRole("link", { name: /coder 定义流/ });
      expect(label).toHaveAttribute("href", "/p/app-1/t/t7");
      expect(message).toHaveTextContent("~052ca4");
    } finally {
      vi.mocked(directory).mockResolvedValue(ok({ sessions: [session(1, { handle: "main", address: "main", title: "值班", state: "running" }), session(2)] }) as never);
    }
  });

  test("a message the agent sent to another session is a row of its own: whom it asked (the session's title, linked) and what", async () => {
    vi.mocked(directory).mockResolvedValue(ok({ sessions: [session(7, { address: "~052ca4", title: "coder 定义流" }), session(2)] }) as never);
    try {
      await open();
      act(() =>
        channel.deliver("event", {
          seq: 4,
          method: "item/completed",
          params: {
            turnId: "turn_2",
            item: {
              id: "fc_send",
              type: "dynamicToolCall",
              turnId: "turn_2",
              namespace: "agents",
              tool: "send_message",
              arguments: { to: "~052ca4", message: "这些文件是你建的吗？请先回报，别再改。", deliver: "now" },
              status: "completed",
              success: true,
              contentItems: [{ type: "inputText", text: "sent to ~052ca4" }],
            },
          },
        }),
      );
      const row = await screen.findByTestId("tool-send-message");
      expect(row).toHaveTextContent("问了");
      expect(await within(row).findByRole("link", { name: /coder 定义流/ })).toHaveAttribute("href", "/p/app-1/t/t7");
      expect(row).toHaveTextContent("这些文件是你建的吗");
      // a team member by name: no link, the name as it is
      act(() =>
        channel.deliver("event", {
          seq: 5,
          method: "item/completed",
          params: {
            turnId: "turn_2",
            item: { id: "fc_send2", type: "dynamicToolCall", turnId: "turn_2", namespace: "agents", tool: "send_message", arguments: { to: "researcher", message: "再查一下" }, status: "completed", success: true, contentItems: [] },
          },
        }),
      );
      const rows = await screen.findAllByTestId("tool-send-message");
      expect(rows[1]).toHaveTextContent("researcher");
      expect(within(rows[1]!).queryByRole("link")).not.toBeInTheDocument();
    } finally {
      vi.mocked(directory).mockResolvedValue(ok({ sessions: [session(1, { handle: "main", address: "main", title: "值班", state: "running" }), session(2)] }) as never);
    }
  });

  test("view_image is routed to a localized preview card instead of the generic JSON fallback", async () => {
    await open();
    act(() => channel.deliver("event", {
      seq: 4, method: "item/completed", params: {
        turnId: "turn_2",
        item: {
          id: "view-image-1", type: "dynamicToolCall", turnId: "turn_2",
          namespace: "view_image", tool: "view_image",
          arguments: { path: "/tmp/截图.png" }, status: "completed", success: true,
          contentItems: [{ type: "inputText", text: "attached /tmp/截图.png" }],
          details: { name: "截图.png", path: "snapshot.png", mime: "image/png", bytes: 1024, attachment: true },
        },
      },
    }));
    const row = await screen.findByTestId("tool-view-image");
    expect(row).toHaveTextContent("查看了图片");
    expect(within(row).getByRole("img", { name: "截图.png" })).toHaveAttribute("src", "/files/id-1/_attachments/snapshot.png?inline=1");
    expect(within(row).queryByText(/Used tool|contentItems/)).not.toBeInTheDocument();
    fireEvent.click(within(row).getByRole("button", { name: "点击查看大图" }));
    expect(screen.getByRole("dialog", { name: "图片大图" })).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "关闭大图" }));
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  });

  test("an attachment the person sent is a chip in their bubble, not the tag and the note the model reads", async () => {
    await open();
    act(() =>
      channel.deliver("event", {
        seq: 4,
        method: "item/completed",
        params: {
          turnId: "turn_2",
          item: {
            id: "u10",
            type: "userMessage",
            turnId: "turn_2",
            content: [{ type: "text", text: "看看这个\n\n<attachment name=\"factors_raw.jsonl\" path=\"/data/attachments/p1/20260920T074549-factors_raw.jsonl\" size=\"177 KB\" />（文件已存到服务器上的这个路径，需要时直接读取或解压）" }],
          },
        },
      }),
    );
    const chip = await screen.findByText(/factors_raw\.jsonl/);
    expect(chip.closest("[data-slot=directive-text-chip]")).toHaveAttribute("data-directive-type", "attachment");
    expect(chip.closest("[data-slot=directive-text-chip]")).toHaveTextContent("177 KB");
    expect(screen.queryByText(/文件已存到服务器/)).not.toBeInTheDocument();
    expect(screen.queryByText(/<attachment/)).not.toBeInTheDocument();
    expect(screen.getByText(/看看这个/)).toBeInTheDocument();
  });

  test("the badge names the model and level a turn ran on; a sub-agent's row names its child's", async () => {
    const user = userEvent.setup();
    vi.mocked(listSubagents).mockResolvedValue(ok([{ ...thread(9), id: "t9", kernelThreadId: "thr_1-gamma", title: "gamma", agentPath: "/root/gamma", status: "active" }]) as never);
    try {
      await open();
      const child = "thr_1-gamma";
      act(() => {
        channel.deliverTo("thread:thr_1", "event", { seq: 4, method: "turn/started", params: { turn: { id: "turn_2", status: "inProgress", startedAt: 1_700_000_000 } } });
        channel.deliverTo("thread:thr_1", "event", { seq: 5, method: "turn/model", params: { turnId: "turn_2", model: "glm-5", name: "pro", effort: "high" } });
        channel.deliverTo("thread:thr_1", "event", {
          seq: 6,
          method: "item/completed",
          params: { turnId: "turn_2", item: { id: "act_gamma", type: "subAgentActivity", agentPath: "/root/gamma", agentThreadId: child, kind: "started" } },
        });
        channel.deliverTo("thread:thr_1", "event", { seq: 7, method: "item/completed", params: { turnId: "turn_2", item: { id: "a2", type: "agentMessage", turnId: "turn_2", text: "sent gamma" } } });
        channel.deliverTo("thread:thr_1", "event", { seq: 8, method: "turn/completed", params: { turn: { id: "turn_2", status: "completed", startedAt: 1_700_000_000, completedAt: 1_700_000_004, usage: { totalTokens: 10, outputTokens: 4 } } } });
      });
      await waitFor(() => expect(channel.topics).toContain(`thread:${child}`));
      act(() =>
        channel.replyTo(`thread:${child}`, "ok", {
          thread_id: child,
          seq: 2,
          thread: null,
          turn: { id: "turn_2-gamma", status: "inProgress", model: "deepseek-flash", modelName: null, effort: "low" },
          status: null,
          token_usage: null,
          items: [{ id: "m_gamma", type: "agentMessage", turnId: "turn_2-gamma", text: "hi" }],
          pending_requests: [],
        }),
      );
      const sub = screen.getByTestId("tool-subagent");
      expect(sub).toHaveTextContent("deepseek-flash · low");
      // the parent's badge: the model behind the popover
      const badges = screen.getAllByRole("button", { name: /耗时/ });
      await user.hover(badges[badges.length - 1]!);
      expect(await screen.findByText(/glm-5/)).toBeInTheDocument();
      expect(screen.getByText(/pro · high/)).toBeInTheDocument();
    } finally {
      vi.mocked(listSubagents).mockResolvedValue(ok([]) as never);
    }
  });

  test("a working sub-agent's row says what its model is writing and can be stopped from the parent's page", async () => {
    const user = userEvent.setup();
    vi.mocked(listSubagents).mockResolvedValue(ok([{ ...thread(9), id: "t9", kernelThreadId: "thr_1-beta", title: "beta", agentPath: "/root/beta", status: "active" }]) as never);
    try {
      await open();
      const child = "thr_1-beta";
      act(() => {
        channel.deliverTo("thread:thr_1", "event", { seq: 4, method: "turn/started", params: { turn: { id: "turn_2", status: "inProgress" } } });
        channel.deliverTo("thread:thr_1", "event", {
          seq: 5,
          method: "item/completed",
          params: { turnId: "turn_2", item: { id: "act_beta", type: "subAgentActivity", agentPath: "/root/beta", agentThreadId: child, kind: "started" } },
        });
        channel.deliverTo("thread:thr_1", "event", { seq: 6, method: "turn/completed", params: { turn: { id: "turn_2", status: "completed" } } });
      });
      await waitFor(() => expect(channel.topics).toContain(`thread:${child}`));
      act(() =>
        channel.replyTo(`thread:${child}`, "ok", {
          thread_id: child,
          seq: 2,
          thread: null,
          turn: { id: "turn_2-beta", status: "inProgress" },
          status: null,
          token_usage: null,
          items: [{ id: "m_beta", type: "agentMessage", turnId: "turn_2-beta", text: "writing the note…" }],
          pending_requests: [],
          progress: { kind: "toolCall", name: "apply_patch", bytes: 20480 },
        }),
      );
      // The top-right resource entrance opens the agents' live states.
      await user.click(await screen.findByRole("button", { name: "Agent 1" }));
      const panel = await screen.findByTestId("thread-agents-popover");
      expect(panel).toHaveTextContent("beta");
      expect(panel).toHaveTextContent("正在写 apply_patch 的参数（20 KB）");
      expect(screen.queryByTestId("agents-bar")).not.toBeInTheDocument();
      await user.keyboard("{Escape}");
      expect(screen.queryByTestId("thread-agents-popover")).not.toBeInTheDocument();
      await user.click(screen.getByRole("button", { name: "Agent 1" }));
      expect(screen.getByTestId("thread-agents-popover")).toHaveTextContent("apply_patch");
      // stop from the card
      await user.click(within(screen.getByTestId("thread-agents-popover")).getByRole("button", { name: "停止 beta" }));
      await waitFor(() => expect(interruptTurn).toHaveBeenCalledWith(expect.objectContaining({ input: { threadId: "t9", kernelTurnId: "turn_2-beta" } })));
      await user.keyboard("{Escape}");
      const sub = screen.getByTestId("tool-subagent");
      // the row is a summary — state, what its model is writing, its last words — never the conversation
      expect(sub).toHaveTextContent("正在写 apply_patch 的参数（20 KB）");
      expect(sub).toHaveTextContent("writing the note…");
      expect(within(sub).queryByTestId("subagent-messages")).not.toBeInTheDocument();
      await user.click(within(sub).getByRole("button", { name: "停止" }));
      await waitFor(() => expect(interruptTurn).toHaveBeenCalledWith(expect.objectContaining({ input: { threadId: "t9", kernelTurnId: "turn_2-beta" } })));
      // 打开: the conversation in a workbench tab, live, with the way to its own page
      await user.click(within(sub).getByRole("button", { name: "打开" }));
      const tabs = await screen.findByTestId("workbench-tabs");
      expect(within(tabs).getByRole("tab", { name: /beta/ })).toHaveAttribute("aria-selected", "true");
      const pane = await screen.findByTestId("agent-tab");
      // the child's words stream in (smooth text): wait for them
      expect(await within(pane).findByText(/writing the note/, {}, { timeout: 3000 })).toBeInTheDocument();
      expect(within(pane).getByRole("link", { name: /到它的页面/ })).toHaveAttribute("href", "/p/app-1/t/t9");
      act(() => {
        channel.deliverTo(`thread:${child}`, "event", { seq: 3, method: "item/completed", params: { turnId: "turn_2-beta", item: { id: "m_beta2", type: "agentMessage", turnId: "turn_2-beta", text: "note written" } } });
      });
      expect(await within(pane).findByText("note written")).toBeInTheDocument();
      // the child's turn ends: the card keeps it under 最近完成 (the report is a click away)
      act(() => {
        channel.deliverTo(`thread:${child}`, "event", { seq: 4, method: "turn/completed", params: { turn: { id: "turn_2-beta", status: "completed" } } });
      });
      await user.click(within(within(tabs).getAllByRole("tab")[0]!).getAllByRole("button")[0]!);
      await user.click(screen.getByRole("button", { name: "Agent 1" }));
      await waitFor(() => expect(screen.getByTestId("thread-agents-popover")).toHaveTextContent("最近完成"));
      expect(screen.getByTestId("thread-agents-popover")).toHaveTextContent("beta");
    } finally {
      vi.mocked(listSubagents).mockResolvedValue(ok([]) as never);
    }
  });

  test("a sub-agent joins its own thread: its row sums it up under the parent, its ask is answered there", async () => {
    const user = userEvent.setup();
    await open();
    const child = "thr_1-alpha";
    act(() => {
      channel.deliverTo("thread:thr_1", "event", {
        seq: 4,
        method: "turn/started",
        params: { turn: { id: "turn_2", status: "inProgress" } },
      });
      channel.deliverTo("thread:thr_1", "event", {
        seq: 6,
        method: "item/completed",
        params: {
          turnId: "turn_2",
          item: {
            id: "act_alpha_started",
            type: "subAgentActivity",
            agentPath: "/root/alpha",
            agentThreadId: child,
            kind: "started",
          },
        },
      });
    });
    // the parent's activity opened the child's channel
    await waitFor(() => expect(channel.topics).toContain(`thread:${child}`));
    act(() =>
      channel.replyTo(`thread:${child}`, "ok", {
        thread_id: child,
        seq: 2,
        thread: null,
        turn: { id: "turn_2-alpha", status: "inProgress" },
        status: null,
        token_usage: null,
        items: [
          {
            id: "cmd_alpha",
            type: "commandExecution",
            turnId: "turn_2-alpha",
            command: "echo alpha",
            cwd: "/p",
            status: "inProgress",
          },
        ],
        pending_requests: [
          {
            id: 9,
            method: "longx/action/request",
            params: { requestId: 9, itemId: "cmd_alpha", threadId: child, title: "登录 alpha 的账号", text: "", url: null },
          },
        ],
      }),
    );
    const sub = screen.getByTestId("tool-subagent");
    expect(sub).toHaveTextContent("alpha");
    // the row is a summary, never the conversation; the child's ask is on it, answered right there
    expect(within(sub).queryByTestId("subagent-messages")).not.toBeInTheDocument();
    expect(within(sub).getByTestId("subagent-ask")).toHaveTextContent("登录 alpha 的账号");
    expect(screen.getByTestId("turn-bar")).toHaveTextContent("等待你操作");
    await user.click(within(sub).getByRole("button", { name: "已完成" }));
    await waitFor(() =>
      expect(answerRequest).toHaveBeenCalledWith(
        expect.objectContaining({
          input: { threadId: "t1", requestId: "9", answers: { done: true } },
        }),
      ),
    );

    act(() => {
      channel.deliverTo(`thread:${child}`, "event", {
        seq: 3,
        method: "serverRequest/resolved",
        params: { requestId: 9 },
      });
      channel.deliverTo(`thread:${child}`, "event", {
        seq: 4,
        method: "item/completed",
        params: {
          turnId: "turn_2-alpha",
          item: {
            id: "cmd_alpha",
            type: "commandExecution",
            command: "echo alpha",
            cwd: "/p",
            status: "completed",
            exitCode: 0,
            aggregatedOutput: "alpha\n",
          },
        },
      });
      channel.deliverTo(`thread:${child}`, "event", {
        seq: 5,
        method: "item/completed",
        params: {
          turnId: "turn_2-alpha",
          item: {
            id: "msg_alpha",
            type: "agentMessage",
            text: "done by alpha",
          },
        },
      });
      channel.deliverTo(`thread:${child}`, "event", {
        seq: 6,
        method: "turn/completed",
        params: { turn: { id: "turn_2-alpha", status: "completed" } },
      });
      channel.deliverTo("thread:thr_1", "event", {
        seq: 7,
        method: "item/completed",
        params: {
          turnId: "turn_2",
          item: {
            id: "act_alpha_done",
            type: "subAgentActivity",
            agentPath: "/root/alpha",
            agentThreadId: child,
            kind: "completed",
          },
        },
      });
    });
    // finished: the row says so with the child's last words; the ask is gone
    expect(screen.getByText("子 agent 完成")).toBeInTheDocument();
    expect(sub).toHaveTextContent("done by alpha");
    expect(within(sub).queryByTestId("subagent-ask")).not.toBeInTheDocument();
  });

  test("the composer rail shows how full the model's context is, from the token usage", async () => {
    await open();
    expect(screen.queryByLabelText("上下文用量")).not.toBeInTheDocument();
    act(() =>
      channel.deliver("event", {
        seq: 4,
        method: "thread/tokenUsage/updated",
        params: {
          turnId: "turn_1",
          tokenUsage: {
            modelContextWindow: 128000,
            last: {
              inputTokens: 30000,
              cachedInputTokens: 2000,
              outputTokens: 2000,
              reasoningOutputTokens: 500,
              totalTokens: 32000,
            },
            total: {
              inputTokens: 30000,
              cachedInputTokens: 2000,
              outputTokens: 2000,
              reasoningOutputTokens: 500,
              totalTokens: 32000,
            },
          },
        },
      }),
    );
    expect(screen.getByLabelText("上下文用量")).toHaveTextContent("25%");
    act(() => {
      channel.deliver("event", {
        seq: 5, method: "turn/started",
        params: { turn: { id: "turn_2", status: "inProgress" } },
      });
      channel.deliver("event", {
        seq: 6, method: "thread/tokenUsage/updated",
        params: { tokenUsage: {
          modelContextWindow: 128000,
          last: { totalTokens: 128000 },
          total: { totalTokens: 128000 },
          context: { status: "pending" },
        } },
      });
    });
    expect(screen.getByLabelText("上下文用量")).toHaveTextContent("—");
    expect(screen.getByTestId("turn-bar")).toHaveTextContent("进行中");
    act(() => channel.deliver("event", {
      seq: 7, method: "thread/tokenUsage/updated",
      params: { tokenUsage: {
        modelContextWindow: 128000,
        last: { totalTokens: 16000 },
        total: { totalTokens: 144000 },
      } },
    }));
    expect(screen.getByLabelText("上下文用量")).toHaveTextContent("13%");
    expect(screen.getByTestId("turn-bar")).toHaveTextContent("进行中");
  });

  test("@ in the composer offers the project's files; the pick is a path in the text, a chip in the message", async () => {
    vi.mocked(searchFiles).mockResolvedValue(
      ok([
        {
          path: "lib/longx/gateway.ex",
          fileName: "gateway.ex",
          matchType: "file",
          root: "/srv/app-1",
          score: 9,
          indices: null,
        },
      ]) as never,
    );
    const user = userEvent.setup();
    const r = renderAt("/p/app-1/t/t1");
    await waitFor(() => expect(channel.topics).toContain("thread:thr_1"));
    act(() =>
      channel.reply("ok", {
        ...snapshot,
        items: [
          {
            id: "u1",
            type: "userMessage",
            turnId: "turn_1",
            content: [{ type: "text", text: "read @lib/a.ex first" }],
          },
          {
            id: "u2",
            type: "userMessage",
            turnId: "turn_1",
            content: [{ type: "text", text: "first line\n\nsecond paragraph" }],
          },
        ],
      }),
    );
    // a mention already in the history is a chip
    const chip = await screen.findByText("lib/a.ex");
    expect(chip.closest("[data-slot=directive-text-chip]")).not.toBeNull();
    // the person's line breaks stay line breaks (a plain message without a chip lost them)
    const plain = screen.getByText(/first line/);
    expect(plain).toHaveClass("whitespace-pre-wrap");
    expect(plain.textContent).toBe("first line\n\nsecond paragraph");

    const box = screen.getByRole("textbox", { name: "随心输入" });
    await user.type(box, "look at @gat");
    // the popover asks the server's index (debounced) and lists the matches
    await user.click(
      await screen.findByRole("option", { name: /gateway\.ex/ }),
    );
    expect(searchFiles).toHaveBeenCalledWith(
      expect.objectContaining({ input: { id: "id-1", query: "gat" } }),
    );
    expect(box).toHaveValue("look at @lib/longx/gateway.ex ");
    await user.type(box, "{Enter}");
    await waitFor(() =>
      expect(sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          input: expect.objectContaining({
            text: "look at @lib/longx/gateway.ex",
          }),
        }),
      ),
    );
    r.unmount();
  });

  test.each(["然后发给 ", "然后发给", "成果接收会话："])("@notes completes an on-duty cross-project recipient after %s and finishes the content here before sharing", async (prefix) => {
    vi.mocked(directory).mockResolvedValue(ok({ sessions: [
      session(1, { onDuty: true, handle: "main", address: "main" }),
      session(9, { projectId: "id-2", projectSlug: "逛论坛", onDuty: true, handle: "notes", address: "逛论坛:notes", title: "接受数据写报告" }),
      session(8, { projectId: "id-2", projectSlug: "逛论坛", address: "逛论坛:off", title: "notes 私人聊天" }),
    ] }) as never);
    try {
      const user = userEvent.setup();
      await open();
      const composer = screen.getByRole("textbox", { name: "随心输入" });
      await user.type(composer, `写好这次研究的文章，${prefix}@notes`);
      await user.click(await screen.findByRole("option", { name: /逛论坛:notes/ }));
      expect(screen.queryByRole("option", { name: /私人聊天/ })).not.toBeInTheDocument();
      expect(composer).toHaveValue(`写好这次研究的文章，${prefix}@session("逛论坛:notes") `);
      expect(sendMessage).not.toHaveBeenCalled();
      await user.type(composer, "{Enter}");
      await waitFor(() => expect(sendMessage).toHaveBeenCalledWith(expect.objectContaining({
        input: expect.objectContaining({ text: expect.stringContaining("先在当前会话完成") }),
      })));
      const text = vi.mocked(sendMessage).mock.calls.at(-1)?.[0]?.input?.text as string;
      expect(text).toContain('逛论坛:notes');
      expect(text).toContain("完整正文");
      expect(text).toContain("send_message");
    } finally {
      vi.mocked(directory).mockImplementation(async () => ok({ sessions: [session(1, { handle: "main", address: "main", title: "值班", state: "running", onDuty: true }), session(2)] }) as never);
    }
  });

  test("/ in the composer lists the commands: /compact compacts, /init sends the prompt, /git opens the tool; no /review", async () => {
    const { compactThread } = await import("@/core/api");
    const user = userEvent.setup();
    await open();
    const box = screen.getByRole("textbox", { name: "随心输入" });
    await user.type(box, "/rev");
    expect(screen.queryByRole("option", { name: /review/ })).not.toBeInTheDocument();
    await user.clear(box);

    await user.type(box, "/comp");
    await user.click(await screen.findByRole("option", { name: /compact/ }));
    await waitFor(() =>
      expect(compactThread).toHaveBeenCalledWith(
        expect.objectContaining({ input: { threadId: "t1" } }),
      ),
    );
    expect(box).toHaveValue("");

    await user.type(box, "/init");
    await user.click(await screen.findByRole("option", { name: /init/ }));
    await waitFor(() =>
      expect(sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          input: expect.objectContaining({
            threadId: "t1",
            text: expect.stringContaining("AGENTS.md"),
          }),
        }),
      ),
    );

    await user.type(box, "/git");
    await user.click(await screen.findByRole("option", { name: /git/ }));
    expect(
      within(await screen.findByTestId("tool-panel")).getByTestId("git-tool"),
    ).toBeInTheDocument();
  });

  test("an image can be attached (the button, the picker) and goes with the message; a sent image shows in the transcript", async () => {
    const user = userEvent.setup();
    await open();
    // the button opens the native picker (nothing a test can drive); a drop stages the file the same way
    expect(screen.getByRole("button", { name: "添加附件" })).toBeEnabled();
    const file = new File([new Uint8Array([137, 80, 78, 71])], "shot.png", {
      type: "image/png",
    });
    const shell = document.querySelector("[data-slot=aui_composer-shell]")!;
    fireEvent.drop(shell, {
      dataTransfer: { files: [file], types: ["Files"] },
    });
    await screen.findByRole("button", { name: /image attachment/i });
    const box = screen.getByRole("textbox", { name: "随心输入" });
    await user.type(box, "what is this{Enter}");
    await waitFor(() =>
      expect(sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          input: expect.objectContaining({
            text: "what is this",
            images: [expect.stringMatching(/^data:image\/png;base64,/)],
          }),
        }),
      ),
    );

    act(() =>
      channel.deliver("event", {
        seq: 4,
        method: "item/completed",
        params: {
          threadId: "thr_1",
          turnId: "turn_2",
          item: {
            id: "u2",
            type: "userMessage",
            content: [
              { type: "text", text: "what is this" },
              { type: "image", url: "data:image/png;base64,iVBORw0KGgo=" },
            ],
          },
        },
      }),
    );
    await waitFor(() =>
      expect(
        document.querySelector("img[src^='data:image/png']"),
      ).not.toBeNull(),
    );
  });

  test("any other file — a zip — is uploaded to the server when dropped and the message names its path", async () => {
    const user = userEvent.setup();
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ path: "/data/attachments/id-1/20260916T020000-data.zip", name: "data.zip", bytes: 4 }), { status: 200 }),
    );
    await open();
    const file = new File([new Uint8Array([80, 75, 3, 4])], "data.zip", { type: "application/zip" });
    const shell = document.querySelector("[data-slot=aui_composer-shell]")!;
    fireEvent.drop(shell, { dataTransfer: { files: [file], types: ["Files"] } });
    await screen.findByRole("button", { name: /file attachment/i });
    await waitFor(() => expect(fetchMock).toHaveBeenCalledWith("/attachments/id-1", expect.objectContaining({ method: "POST" })));
    const box = screen.getByRole("textbox", { name: "随心输入" });
    await user.type(box, "unpack it{Enter}");
    await waitFor(() =>
      expect(sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          input: expect.objectContaining({
            text: expect.stringMatching(/^unpack it\n\n<attachment name="data\.zip" path="\/data\/attachments\/id-1\/20260916T020000-data\.zip"/),
          }),
        }),
      ),
    );
    fetchMock.mockRestore();
  });

  test("a text file past 32 KB is uploaded like a zip and the message names its path — never inlined into the prompt", async () => {
    const user = userEvent.setup();
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ path: "/data/attachments/id-1/20260928T020000-dump.txt", name: "dump.txt", bytes: 40 * 1024 }), { status: 200 }),
    );
    await open();
    const file = new File([new Uint8Array(40 * 1024).fill(97)], "dump.txt", { type: "text/plain" });
    const shell = document.querySelector("[data-slot=aui_composer-shell]")!;
    fireEvent.drop(shell, { dataTransfer: { files: [file], types: ["Files"] } });
    await waitFor(() => expect(fetchMock).toHaveBeenCalledWith("/attachments/id-1", expect.objectContaining({ method: "POST" })));
    const box = screen.getByRole("textbox", { name: "随心输入" });
    await user.type(box, "summarise it{Enter}");
    await waitFor(() =>
      expect(sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          input: expect.objectContaining({
            text: expect.stringMatching(/^summarise it\n\n<attachment name="dump\.txt" path="\/data\/attachments\/id-1\/20260928T020000-dump\.txt"/),
          }),
        }),
      ),
    );
    const sent = vi.mocked(sendMessage).mock.lastCall![0] as { input: { text: string } };
    expect(sent.input.text).not.toContain("aaaa");
    fetchMock.mockRestore();
  });

  test("what the person sends shows in the thread at once, marked 发送中…, and gives way to the server's item when it lands", async () => {
    const user = userEvent.setup();
    let land!: (value: unknown) => void;
    vi.mocked(sendMessage).mockImplementationOnce(() => new Promise((resolve) => { land = resolve; }) as never);
    await open();
    const box = screen.getByRole("textbox", { name: "随心输入" });
    await user.type(box, "quick one{Enter}");
    // before the RPC answered, before any event: the message is there, faded, with a word
    const echo = await screen.findByText("quick one");
    expect(echo.closest("[data-pending]")).toHaveAttribute("data-pending", "message");
    expect(screen.getByTestId("pending-note")).toHaveTextContent("发送中…");

    act(() => land(ok({ id: "turn-row" })));
    // as the kernel sends them: the turn's start and the person's item in one batch
    act(() => {
      channel.deliver("event", { seq: 4, method: "turn/started", params: { turn: { id: "turn_2", status: "inProgress" } } });
      channel.deliver("event", {
        seq: 5,
        method: "item/started",
        params: { turnId: "turn_2", item: { id: "u2", type: "userMessage", turnId: "turn_2", content: [{ type: "text", text: "quick one" }] } },
      });
    });
    await waitFor(() => expect(screen.queryByTestId("pending-note")).not.toBeInTheDocument());
    expect(screen.getAllByText("quick one")).toHaveLength(1);

    // the answer streams in under it: no branch picker anywhere — the echo giving way to
    // the server's item is not an edit (assistant-ui once counted the two as branches, "2 / 2")
    act(() => {
      channel.deliver("event", { seq: 6, method: "item/started", params: { turnId: "turn_2", item: { id: "a2", type: "agentMessage", turnId: "turn_2", text: "" } } });
      channel.deliver("event", { seq: 7, method: "item/completed", params: { turnId: "turn_2", item: { id: "a2", type: "agentMessage", turnId: "turn_2", text: "quick answer" } } });
      channel.deliver("event", { seq: 8, method: "turn/completed", params: { turn: { id: "turn_2", status: "completed" } } });
    });
    await screen.findByText("quick answer");
    expect(screen.queryByText(/^\d+ \/ \d+$/)).not.toBeInTheDocument();
    expect(document.querySelector(".aui-branch-picker-root")).toBeNull();
  });

  test("a send that failed keeps its echo, in red, with the reason", async () => {
    const user = userEvent.setup();
    vi.mocked(sendMessage).mockResolvedValueOnce(failed("turn_in_progress") as never);
    await open();
    await user.type(screen.getByRole("textbox", { name: "随心输入" }), "again{Enter}");
    await waitFor(() => expect(screen.getByTestId("pending-note")).toHaveTextContent("没发出去：turn_in_progress"));
    expect(screen.getByText("again").closest("[data-pending]")).toHaveAttribute("data-pending", "message");
    // the next message goes out at once (assistant-ui's queue would have held it for a turn that never ended)
    await user.type(screen.getByRole("textbox", { name: "随心输入" }), "once more{Enter}");
    await waitFor(() => expect(sendMessage).toHaveBeenCalledTimes(2));
    // the failed echo made way for the new one
    await waitFor(() => expect(screen.queryByText("again")).not.toBeInTheDocument());
  });

  test("voice input is switched off for now: no mic in the rail", async () => {
    await open();
    expect(screen.queryByRole("button", { name: "语音输入" })).toBeNull();
  });

  test("↑ on an empty composer recalls the last message sent", async () => {
    const user = userEvent.setup();
    await open();
    const box = screen.getByRole("textbox", { name: "随心输入" });
    await user.click(box);
    await user.keyboard("{ArrowUp}");
    expect(box).toHaveValue("run the tests");
  });

  test("renderers: fenced code highlights with shiki, a mermaid fence is a diagram, reasoning is the step panel — folded until opened, the choice kept", async () => {
    const r = renderAt("/p/app-1/t/t1");
    await waitFor(() => expect(channel.topics).toContain("thread:thr_1"));
    act(() =>
      channel.reply("ok", {
        ...snapshot,
        turn: { id: "turn_1", status: "inProgress" },
        items: [
          {
            id: "u1",
            type: "userMessage",
            turnId: "turn_1",
            content: [{ type: "text", text: "draw it" }],
          },
          {
            id: "r1",
            type: "reasoning",
            turnId: "turn_1",
            summary: ["**Planning**\n\nfirst the schema then the diagram"],
            content: [],
          },
        ],
      }),
    );
    await screen.findByText("draw it");
    // the turn is running and reasoning is what streams: the panel shimmers but stays
    // folded (a page unfolding every thought was too long); a click opens its titled steps
    const panel = document.querySelector("[data-slot=reasoning-panel]")!;
    expect(panel).toHaveAttribute("data-state", "closed");
    await userEvent.setup().click(within(panel as HTMLElement).getByRole("button"));
    expect(panel).toHaveAttribute("data-state", "open");
    expect(
      within(panel as HTMLElement).getByText("Planning"),
    ).toBeInTheDocument();
    expect(
      within(panel as HTMLElement).getByText(
        "first the schema then the diagram",
      ),
    ).toBeInTheDocument();
    act(() => {
      channel.deliver("event", {
        seq: 4,
        method: "item/completed",
        params: {
          turnId: "turn_1",
          item: {
            id: "a1",
            type: "agentMessage",
            text: "```elixir\ndefmodule A do\nend\n```\n\n```mermaid\ngraph TD; A-->B;\n```\n",
          },
        },
      });
      channel.deliver("event", {
        seq: 5,
        method: "turn/completed",
        params: { turn: { id: "turn_1", status: "completed" } },
      });
    });
    // settled, the panel shows its resting label and keeps the reader's choice (open); a click folds it
    await screen.findByRole("button", { name: /思考过程/ });
    expect(document.querySelector("[data-slot=reasoning-panel]")).toHaveAttribute("data-state", "open");
    await userEvent.click(screen.getByRole("button", { name: /思考过程/ }));
    await waitFor(() =>
      expect(
        document.querySelector("[data-slot=reasoning-panel]"),
      ).toHaveAttribute("data-state", "closed"),
    );
    // code goes through the shiki highlighter (plain until tokenised), mermaid through the diagram element
    await waitFor(() =>
      expect(document.querySelector(".aui-shiki-base")).toHaveTextContent(
        "defmodule A do",
      ),
    );
    await waitFor(() =>
      expect(document.querySelector("[data-slot^=mermaid-]")).not.toBeNull(),
    );
    expect(
      document.querySelector(".aui-shiki-base")?.textContent,
    ).not.toContain("graph TD");
    r.unmount();
  });

  test("the synthetic activity dot hides during a stall and the no-output hint clears when the turn completes", async () => {
    const r = renderAt("/p/app-1/t/t1");
    await waitFor(() => expect(channel.topics).toContain("thread:thr_1"));
    act(() =>
      channel.reply("ok", {
        ...snapshot,
        turn: { id: "turn_1", status: "inProgress" },
        items: [
          { id: "u1", type: "userMessage", turnId: "turn_1", content: [{ type: "text", text: "thinking" }] },
          { id: "c1", type: "commandExecution", turnId: "turn_1", command: "long-running command", cwd: "/p", status: "inProgress", aggregatedOutput: "" },
        ],
      }),
    );
    await screen.findByText("thinking");
    const indicator = () => document.querySelector('[data-slot="aui_assistant-message-indicator"]');
    expect(indicator()).toBeInTheDocument();
    await act(async () => new Promise((resolve) => globalThis.setTimeout(resolve, 15_100)));
    expect(indicator()).toBeNull();
    const hint = document.querySelector("[data-slot=aui_assistant-message-stalled]");
    expect(hint).toBeInTheDocument();
    const firstElapsed = Number(hint!.textContent!.match(/\d+/)?.[0]);
    await act(async () => new Promise((resolve) => globalThis.setTimeout(resolve, 1_100)));
    const secondElapsed = Number(document.querySelector("[data-slot=aui_assistant-message-stalled]")!.textContent!.match(/\d+/)?.[0]);
    expect(secondElapsed).toBeGreaterThan(firstElapsed);

    act(() =>
      channel.deliver("event", {
        seq: 4,
        method: "turn/completed",
        params: { turn: { id: "turn_1", status: "completed" } },
      }),
    );
    await waitFor(() =>
      expect(document.querySelector("[data-slot=aui_assistant-message-stalled]")).toBeNull(),
    );
    r.unmount();
  }, 25_000);

  test("phone: the chat still shows the command block and the bottom toolbar", async () => {
    setViewport(390);
    await open();
    expect(screen.getByTestId("bottom-toolbar")).toBeInTheDocument();
    expect(
      within(screen.getByTestId("chat-area")).getByTestId("tool-command"),
    ).toBeInTheDocument();
  });

  test("phone: a child at work is a pill at the chat's top right that opens the Agent sheet, where the inbox says what it does", async () => {
    setViewport(390);
    const user = userEvent.setup();
    vi.mocked(listSubagents).mockResolvedValue(ok([{ ...thread(9), id: "t9", kernelThreadId: "thr_1-beta", title: "beta", agentPath: "/root/beta", status: "active" }]) as never);
    try {
      await open();
      const child = "thr_1-beta";
      act(() => {
        channel.deliverTo("thread:thr_1", "event", { seq: 4, method: "turn/started", params: { turn: { id: "turn_2", status: "inProgress" } } });
        channel.deliverTo("thread:thr_1", "event", {
          seq: 5,
          method: "item/completed",
          params: { turnId: "turn_2", item: { id: "act_beta", type: "subAgentActivity", agentPath: "/root/beta", agentThreadId: child, kind: "started" } },
        });
        channel.deliverTo("thread:thr_1", "event", { seq: 6, method: "turn/completed", params: { turn: { id: "turn_2", status: "completed" } } });
      });
      await waitFor(() => expect(channel.topics).toContain(`thread:${child}`));
      act(() =>
        channel.replyTo(`thread:${child}`, "ok", {
          thread_id: child,
          seq: 2,
          thread: null,
          turn: { id: "turn_2-beta", status: "inProgress" },
          status: null,
          token_usage: null,
          items: [],
          pending_requests: [],
          progress: { kind: "toolCall", name: "apply_patch", bytes: 20480 },
        }),
      );
      expect(screen.queryByTestId("agents-panel")).not.toBeInTheDocument();
      const pill = await screen.findByRole("button", { name: "Agent 1" });
      await user.click(pill);
      const sheet = await screen.findByTestId("thread-agents-popover", {}, { timeout: 3000 });
      expect(await within(sheet).findByText("beta")).toBeInTheDocument();
      expect(sheet).toHaveTextContent("正在写 apply_patch 的参数（20 KB）");
    } finally {
      vi.mocked(listSubagents).mockResolvedValue(ok([]) as never);
    }
  });

  const surfaceItem = (id: string, tool: string, args: Record<string, unknown>, details: Record<string, unknown>) => ({
    id,
    type: "dynamicToolCall",
    turnId: "turn_2",
    namespace: "longx",
    tool,
    arguments: args,
    status: "completed",
    success: true,
    contentItems: [],
    durationMs: 3,
    details,
  });

  test("a show_file item arriving live opens the file in the workbench; one replayed from the snapshot only draws its row", async () => {
    // the snapshot holds a show_file of an earlier turn: no tab opens for it
    const r = renderAt("/p/app-1/t/t1");
    await waitFor(() => expect(channel.topics).toContain("thread:thr_1"));
    act(() => channel.reply("ok", { ...snapshot, items: [...snapshot.items, surfaceItem("s0", "show_file", { path: "old.ex" }, { path: "old.ex", line: null })] }));
    await screen.findByText("run the tests");
    expect(screen.getByTestId("tool-show-file")).toHaveTextContent("old.ex");
    expect(within(screen.getByTestId("workbench-tabs")).getAllByRole("tab")).toHaveLength(1);
    expect(screen.getByTestId("workbench-tabs")).not.toHaveTextContent("old.ex");
    // live: the editor tab opens at once
    act(() => {
      channel.deliver("event", { seq: 4, method: "turn/started", params: { turn: { id: "turn_2", status: "inProgress" } } });
      channel.deliver("event", { seq: 5, method: "item/completed", params: { turnId: "turn_2", item: surfaceItem("s1", "show_file", { path: "a.ex", line: 3 }, { path: "lib/a.ex", line: 3 }) } });
    });
    await waitFor(() => expect(screen.getByTestId("workbench-tabs")).toHaveTextContent("a.ex"));
    expect(screen.getByRole("tab", { selected: true })).toHaveTextContent("a.ex");
    r.unmount();
  });

  test("show_html opens an artifact tab: the html in a sandboxed frame, no same-origin", async () => {
    await open();
    act(() => {
      channel.deliver("event", { seq: 4, method: "turn/started", params: { turn: { id: "turn_2", status: "inProgress" } } });
      channel.deliver("event", { seq: 5, method: "item/completed", params: { turnId: "turn_2", item: surfaceItem("s2", "show_html", { title: "销量图", html: "<h1>hi</h1>" }, { kind: "html", title: "销量图", bytes: 11 }) } });
    });
    const frame = await screen.findByTitle("销量图");
    expect(frame.tagName).toBe("IFRAME");
    expect(frame).toHaveAttribute("sandbox", "allow-scripts allow-forms");
    expect(frame).toHaveAttribute("srcdoc", "<h1>hi</h1>");
    expect(frame).toHaveAttribute("referrerpolicy", "no-referrer");
    expect(screen.getByRole("tab", { selected: true })).toHaveTextContent("销量图");
  });

  test("phone: an artifact is a full-screen sheet over the chat, closed with its button", async () => {
    const user = userEvent.setup();
    setViewport(390);
    await open();
    act(() => {
      channel.deliver("event", { seq: 4, method: "turn/started", params: { turn: { id: "turn_2", status: "inProgress" } } });
      channel.deliver("event", { seq: 5, method: "item/completed", params: { turnId: "turn_2", item: surfaceItem("s3", "show_html", { title: "销量图", html: "<h1>hi</h1>" }, { kind: "html", title: "销量图", bytes: 11 }) } });
    });
    const sheet = await screen.findByTestId("artifact-sheet");
    expect(within(sheet).getByTitle("销量图")).toHaveAttribute("sandbox", "allow-scripts allow-forms");
    await user.click(within(sheet).getByRole("button", { name: /关闭/ }));
    await waitFor(() => expect(screen.queryByTestId("artifact-sheet")).not.toBeInTheDocument());
    expect(screen.getByTestId("tool-show-html")).toBeInTheDocument();
  });

  test("a tool asking the person to act: a card with the link, 等待你操作 in the rail; 已完成 answers the request", async () => {
    const user = userEvent.setup();
    await open();
    act(() => {
      channel.deliver("event", { seq: 4, method: "turn/started", params: { turn: { id: "turn_2", status: "inProgress" } } });
      channel.deliver("event", {
        seq: 5,
        method: "longx/action/request",
        params: { requestId: "ask_1", itemId: "call_7", threadId: "thr_1", title: "登录 COROS", text: "用存有训练数据的账号登录", url: "https://auth.example/authorize?x=1", callbackUrl: "http://192.168.2.129:7788/callback/ask_1" },
      });
    });
    const card = await screen.findByTestId("tool-action");
    expect(card).toHaveTextContent("登录 COROS");
    expect(card).toHaveTextContent("用存有训练数据的账号登录");
    expect(within(card).getByRole("link", { name: "打开链接" })).toHaveAttribute("href", "https://auth.example/authorize?x=1");
    expect(screen.getByTestId("turn-bar")).toHaveTextContent("等待你操作");
    await user.click(within(card).getByRole("button", { name: "已完成" }));
    await waitFor(() =>
      expect(answerRequest).toHaveBeenCalledWith(expect.objectContaining({ input: { threadId: "t1", requestId: "ask_1", answers: { done: true } } })),
    );
  });

  test("a tier runs at its own level: the rail names it, the picker follows it until a level is picked, and following it again sends none", async () => {
    const user = userEvent.setup();
    vi.mocked(listModels).mockResolvedValue(
      ok([
        model(1, { slug: "deepseek-flash", default: true, reasoningLevels: ["low", "high", "max"], reasoningEffort: "high" }),
        model(2, { slug: "glm-5", reasoningLevels: ["low", "high"], reasoningEffort: "high" }),
      ]) as never,
    );
    vi.mocked(modelAliases).mockResolvedValue(
      ok([
        { name: "ultra", label: "旗舰", models: [], efforts: [], builtin: true },
        { name: "pro", label: "高级", models: ["glm-5"], efforts: ["low"], builtin: true },
        { name: "plus", label: "普通", models: [], efforts: [], builtin: true },
      ]) as never,
    );
    try {
      await open();
      await user.click(await screen.findByTestId("model-picker"));
      await user.click(await screen.findByRole("option", { name: /^pro/ }));
      // pro is glm-5 at low: the tier's level, not the model's default
      await waitFor(() => expect(screen.getByTestId("model-picker")).toHaveTextContent(/pro\s*glm-5\s*low/));
      await user.click(screen.getByTestId("model-picker"));
      expect(await screen.findByRole("radio", { name: "跟随档位 · low" })).toBeChecked();
      await user.click(screen.getByRole("radio", { name: "high" }));
      await user.keyboard("{Escape}");
      expect(screen.getByTestId("model-picker")).toHaveTextContent("high");
      await user.type(screen.getByRole("textbox", { name: "随心输入" }), "go{Enter}");
      await waitFor(() =>
        expect(sendMessage).toHaveBeenLastCalledWith(expect.objectContaining({ input: expect.objectContaining({ model: "pro", effort: "high" }) })),
      );

      // back to the tier's own level: nothing chosen goes out
      await user.click(screen.getByTestId("model-picker"));
      await user.click(await screen.findByRole("radio", { name: "跟随档位 · low" }));
      await user.keyboard("{Escape}");
      expect(screen.getByTestId("model-picker")).toHaveTextContent("low");
    } finally {
      vi.mocked(modelAliases).mockResolvedValue(
        ok([
          { name: "ultra", label: "旗舰", models: ["glm-5", "deepseek-flash"], efforts: [null, null], builtin: true },
          { name: "pro", label: "高级", models: [], efforts: [], builtin: true },
          { name: "plus", label: "普通", models: [], efforts: [], builtin: true },
        ]) as never,
      );
    }
  });

  test("inside a native shell a tier is followed by its levels too, the tier's own first", async () => {
    const posts: Record<string, unknown>[] = [];
    window.LongxAndroid = { post: (json: string) => posts.push(JSON.parse(json)) };
    vi.mocked(listModels).mockResolvedValue(
      ok([
        model(1, { slug: "deepseek-flash", default: true, reasoningLevels: ["low", "high"], reasoningEffort: "high" }),
        model(2, { slug: "glm-5", reasoningLevels: ["low", "high"], reasoningEffort: "high" }),
      ]) as never,
    );
    vi.mocked(modelAliases).mockResolvedValue(
      ok([
        { name: "ultra", label: "旗舰", models: [], efforts: [], builtin: true },
        { name: "pro", label: "高级", models: ["deepseek-flash"], efforts: ["low"], builtin: true },
        { name: "plus", label: "普通", models: [], efforts: [], builtin: true },
      ]) as never,
    );
    try {
      const user = userEvent.setup();
      await open();
      await waitFor(() => expect(window.LongxShell).toBeDefined());
      await user.click(screen.getByTestId("model-picker"));
      const pick = posts.find((p) => p["type"] === "pick") as { id: string };
      window.LongxShell!.picked(pick.id, "pro");
      await waitFor(() => expect(posts.filter((p) => p["type"] === "pick")).toHaveLength(2));
      const levels = posts.filter((p) => p["type"] === "pick")[1] as { id: string; sections: { options: { id: string; label: string }[] }[]; selected: string };
      expect(levels.sections[0]!.options.map((o) => o.label)).toEqual(["跟随档位 · low", "low", "high"]);
      expect(levels.selected).toBe(levels.sections[0]!.options[0]!.id);
      window.LongxShell!.picked(levels.id, "high");
      await user.type(screen.getByRole("textbox", { name: "随心输入" }), "go{Enter}");
      await waitFor(() =>
        expect(sendMessage).toHaveBeenLastCalledWith(expect.objectContaining({ input: expect.objectContaining({ model: "pro", effort: "high" }) })),
      );
    } finally {
      delete window.LongxAndroid;
      delete window.LongxShell;
      vi.mocked(modelAliases).mockResolvedValue(
        ok([
          { name: "ultra", label: "旗舰", models: ["glm-5", "deepseek-flash"], efforts: [null, null], builtin: true },
          { name: "pro", label: "高级", models: [], efforts: [], builtin: true },
          { name: "plus", label: "普通", models: [], efforts: [], builtin: true },
        ]) as never,
      );
    }
  });

  test("the picker shows the model the project's description names, and a tier is a choice like a model", async () => {
    vi.mocked(agentDefinition).mockResolvedValue(ok(agentDefinitionData({ present: true, model: "glm-5", effort: "high" })) as never);
    try {
      const user = userEvent.setup();
      await open();
      // the thread picked nothing: the turn runs on the description's model, so that is what the rail says
      await waitFor(() => expect(screen.getByTestId("model-picker")).toHaveTextContent("glm-5"));
      expect(screen.getByTestId("model-picker")).toHaveTextContent("high");
      await user.click(screen.getByTestId("model-picker"));
      await user.click(await screen.findByRole("option", { name: /ultra/ }));
      await user.type(screen.getByRole("textbox", { name: "随心输入" }), "go{Enter}");
      await waitFor(() =>
        expect(sendMessage).toHaveBeenCalledWith(expect.objectContaining({ input: expect.objectContaining({ text: "go", model: "ultra" }) })),
      );
    } finally {
      vi.mocked(agentDefinition).mockResolvedValue(ok(agentDefinitionData()) as never);
    }
  });

  test("a thread that no longer exists (a stale link) says so and offers a new chat", async () => {
    const user = userEvent.setup();
    // not in the list, and not a hidden sub-agent row either
    vi.mocked(getThread).mockResolvedValueOnce(failed("not found", ["id"]) as never);
    const { router } = renderAt("/p/app-1/t/gone");
    await screen.findByText("找不到这个会话");
    await user.click(screen.getByRole("link", { name: "新会话" }));
    await waitFor(() => expect(router.state.location.pathname).toBe("/p/app-1"));
  });
});
