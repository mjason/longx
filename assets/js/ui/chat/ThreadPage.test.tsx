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
import { channel, model, ok, thread } from "@/ui/test-mocks";

vi.mock("@/ash_rpc", async () => (await import("@/ui/test-mocks")).rpcMock());
vi.mock("sonner", async (importOriginal) => {
  const mod = await importOriginal<typeof import("sonner")>();
  return { ...mod, toast: Object.assign(vi.fn(), mod.toast, { warning: vi.fn(), success: vi.fn(), error: vi.fn(), info: vi.fn() }) };
});
import { toast } from "sonner";
vi.mock("@/core/socket", async () =>
  (await import("@/ui/test-mocks")).socketMock(),
);
import {
  answerRequest,
  clearGoal,
  listModels,
  listSkills,
  listThreads,
  respond,
  retractTurn,
  searchFiles,
  sendMessage,
  setGoal,
  startThread,
} from "@/ash_rpc";

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
  beforeEach(() => {
    localStorage.clear();
    _resetFrameStoreForTests();
    channel.reset();
    vi.mocked(sendMessage).mockClear();
    vi.mocked(respond).mockClear();
    vi.mocked(listThreads).mockResolvedValue(ok([thread(1)]) as never);
    setViewport(1280);
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
    await user.click(await screen.findByRole("option", { name: /glm-5/ }));
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
            sandbox: "workspace_write",
          }),
        }),
      ),
    );
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
      expect(pick.selected).toBe("deepseek-flash");
      expect(pick.sections.flatMap((s) => s.options.map((o) => o.id))).toEqual(["deepseek-flash", "glm-5"]);
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
    // the thread runs on the default model at its default level
    expect(screen.getByTestId("model-picker")).toHaveTextContent(
      "deepseek-flash",
    );
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
    const { router } = renderAt("/p/app-1");
    await screen.findByText("让 agent 在这个项目里干活");
    await user.click(screen.getByTestId("model-picker"));
    await user.click(await screen.findByRole("option", { name: /glm-5/ }));
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

  test("live events stream in; an approval can be answered from the message", async () => {
    const user = userEvent.setup();
    await open();
    act(() => {
      channel.deliver("codex", {
        seq: 4,
        method: "turn/started",
        params: { turn: { id: "turn_2", status: "inProgress" } },
      });
      channel.deliver("codex", {
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
      channel.deliver("codex", {
        seq: 6,
        method: "item/commandExecution/requestApproval",
        params: {
          requestId: 7,
          itemId: "c2",
          threadId: "thr_1",
          turnId: "turn_2",
          command: "rm -rf build",
        },
      });
    });
    expect(screen.getByTestId("turn-bar")).toHaveTextContent("等待审批");
    await user.click(screen.getByRole("button", { name: "允许" }));
    await waitFor(() =>
      expect(respond).toHaveBeenCalledWith(
        expect.objectContaining({
          input: { threadId: "t1", requestId: "7", decision: "accept" },
        }),
      ),
    );
    // the composer offers stop while the turn runs
    expect(screen.getByRole("button", { name: /停止/ })).toBeInTheDocument();
  });

  test("stop before anything came back: the turn is taken back and its text is in the composer again, ready to edit", async () => {
    const user = userEvent.setup();
    await open();
    act(() => {
      channel.deliver("codex", { seq: 4, method: "turn/started", params: { turn: { id: "turn_2", status: "inProgress" } } });
      channel.deliver("codex", {
        seq: 5,
        method: "item/completed",
        params: { turnId: "turn_2", item: { id: "u2", type: "userMessage", turnId: "turn_2", content: [{ type: "text", text: "look at pandas" }] } },
      });
    });
    await user.click(await screen.findByRole("button", { name: /停止/ }));
    await waitFor(() => expect(retractTurn).toHaveBeenCalledWith(expect.objectContaining({ input: { threadId: "t1", codexTurnId: "turn_2" } })));
    await waitFor(() => expect(screen.getByRole("textbox", { name: "随心输入" })).toHaveValue("look at pandas"));
  });

  test("an unrecoverable thread cannot take messages", async () => {
    vi.mocked(listThreads).mockResolvedValueOnce({
      success: true,
      data: [
        {
          id: "t1",
          codexThreadId: "thr_1",
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
    expect(screen.getByRole("alert")).toHaveTextContent(
      "codex 已不认识这个会话",
    );
    expect(screen.getByRole("textbox", { name: "随心输入" })).toBeDisabled();
  });

  test("the project route is a new chat: the first message creates the thread (in the picked mode, web search included) and opens it", async () => {
    const user = userEvent.setup();
    const { router } = renderAt("/p/app-1");
    await screen.findByText("让 agent 在这个项目里干活");
    expect(channel.topics.filter((t) => t.startsWith("thread:"))).toEqual([]);
    // web search can only be chosen before the thread exists
    await user.click(screen.getByTestId("mode-picker"));
    const webSearch = await screen.findByRole("switch", { name: /网页搜索/ });
    expect(webSearch).toBeEnabled();
    await user.click(webSearch);
    // so can the sub-agent tools
    const multiAgent = screen.getByRole("switch", { name: /子 agent/ });
    expect(multiAgent).toBeChecked();
    await user.click(multiAgent);
    // and codex's automatic approval review (on by default)
    const autoReview = screen.getByRole("switch", { name: /自动审核/ });
    expect(autoReview).toBeChecked();
    await user.click(autoReview);
    await user.keyboard("{Escape}");
    await user.type(
      screen.getByRole("textbox", { name: "随心输入" }),
      "start here{Enter}",
    );
    await waitFor(() =>
      expect(startThread).toHaveBeenCalledWith(
        expect.objectContaining({
          input: expect.objectContaining({
            projectId: "id-1",
            webSearch: false,
            multiAgent: false,
            autoReview: false,
            sandbox: "workspace_write",
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

  test("the access mode is picked in the composer rail and rides on the next message", async () => {
    const user = userEvent.setup();
    await open();
    await user.click(screen.getByTestId("mode-picker"));
    // an existing thread's web search is fixed
    expect(
      await screen.findByRole("switch", { name: /网页搜索/ }),
    ).toBeDisabled();
    await user.click(
      await screen.findByRole("radio", { name: "完全访问（危险）" }),
    );
    await user.click(screen.getByRole("radio", { name: /全部放行/ }));
    // 全部放行 answers before any reviewer could: the switch is moot
    expect(screen.getByRole("switch", { name: /自动审核/ })).toBeDisabled();
    await user.keyboard("{Escape}");
    expect(screen.getByTestId("mode-picker")).toHaveTextContent("完全访问");
    expect(screen.getByTestId("mode-picker")).toHaveTextContent("全部放行");
    // a phone's rail has no room for the words: the shield icon and the
    // badges say it, the name is the accessible label and lives in the popover
    expect(within(screen.getByTestId("mode-picker")).getByText(/完全访问/)).toHaveClass("hidden", "sm:inline");
    expect(screen.getByTestId("mode-picker")).toHaveAttribute("title", expect.stringContaining("完全访问"));
    await user.type(
      screen.getByRole("textbox", { name: "随心输入" }),
      "go wild{Enter}",
    );
    await waitFor(() =>
      expect(sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          input: expect.objectContaining({
            text: "go wild",
            sandbox: "danger_full_access",
            approvalPolicy: "auto_accept",
            networkAccess: false,
          }),
        }),
      ),
    );
  });

  test("the goal (codex's goal mode) sits above the thread: objective, status, budget; pause / resume / clear; edited in a dialog; /goal opens it", async () => {
    const user = userEvent.setup();
    await open();
    expect(screen.queryByTestId("goal-bar")).not.toBeInTheDocument();
    act(() => {
      channel.deliver("codex", {
        seq: 4,
        method: "thread/goal/updated",
        params: { threadId: "thr_1", turnId: null, goal: { threadId: "thr_1", objective: "让测试全绿", status: "active", tokenBudget: 50000, tokensUsed: 12500, timeUsedSeconds: 125, createdAt: 1, updatedAt: 2 } },
      });
    });
    const bar = await screen.findByTestId("goal-bar");
    expect(bar).toHaveTextContent("让测试全绿");
    expect(bar).toHaveTextContent("进行中");
    expect(bar).toHaveTextContent("12.5k / 50k");
    expect(bar).toHaveTextContent("2 分钟");

    await user.click(within(bar).getByRole("button", { name: "暂停" }));
    await waitFor(() => expect(setGoal).toHaveBeenCalledWith(expect.objectContaining({ input: { threadId: "t1", status: "paused" } })));

    act(() => {
      channel.deliver("codex", {
        seq: 5,
        method: "thread/goal/updated",
        params: { threadId: "thr_1", turnId: null, goal: { threadId: "thr_1", objective: "让测试全绿", status: "paused", tokenBudget: 50000, tokensUsed: 12500, timeUsedSeconds: 125, createdAt: 1, updatedAt: 2 } },
      });
    });
    await waitFor(() => expect(bar).toHaveTextContent("已暂停"));
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
    await waitFor(() => expect(setGoal).toHaveBeenLastCalledWith(expect.objectContaining({ input: { threadId: "t1", objective: "跑通回测", tokenBudget: 80000 } })));

    await user.click(within(bar).getByRole("button", { name: "清除" }));
    await waitFor(() => expect(clearGoal).toHaveBeenCalledWith(expect.objectContaining({ input: { threadId: "t1" } })));
    act(() => channel.deliver("codex", { seq: 6, method: "thread/goal/cleared", params: { threadId: "thr_1" } }));
    await waitFor(() => expect(screen.queryByTestId("goal-bar")).not.toBeInTheDocument());

    // /goal opens the dialog for a new goal
    await user.type(screen.getByRole("textbox", { name: "随心输入" }), "/goal");
    await user.click(await screen.findByRole("option", { name: /goal/ }));
    const fresh = await screen.findByRole("dialog");
    expect(within(fresh).getByLabelText("目标")).toHaveValue("");
  });

  test("codex rerouting the model mid-turn is said in a toast", async () => {
    await open();
    act(() => {
      channel.deliver("codex", {
        seq: 4,
        method: "model/rerouted",
        params: { threadId: "thr_1", turnId: "turn_1", fromModel: "a", toModel: "b", reason: "highRiskCyberActivity" },
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
          codexThreadId: "thr_1",
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
    expect(screen.getByRole("alert")).toHaveTextContent("codex 断开了");
    const box = screen.getByRole("textbox", { name: "随心输入" });
    expect(box).toBeEnabled();
    expect(screen.getByRole("button", { name: "发送" })).toBeDisabled();
  });

  test("a question from codex is a form; the answers go back through answer_request", async () => {
    const user = userEvent.setup();
    await open();
    act(() => {
      channel.deliver("codex", {
        seq: 4,
        method: "turn/started",
        params: { turn: { id: "turn_2", status: "inProgress" } },
      });
      channel.deliver("codex", {
        seq: 5,
        method: "item/tool/requestUserInput",
        params: {
          requestId: 9,
          itemId: "call_9",
          threadId: "thr_1",
          turnId: "turn_2",
          isBlocking: true,
          questions: [
            {
              id: "q1",
              header: "DB",
              question: "which db?",
              options: [{ label: "sqlite", description: "" }],
            },
          ],
        },
      });
    });
    await user.click(screen.getByRole("button", { name: "sqlite" }));
    await user.click(screen.getByRole("button", { name: "发送" }));
    await waitFor(() =>
      expect(answerRequest).toHaveBeenCalledWith(
        expect.objectContaining({
          input: {
            threadId: "t1",
            requestId: "9",
            answers: { q1: { answers: ["sqlite"] } },
          },
        }),
      ),
    );
  });

  test("a finished turn shows its timing; a revert re-pulls the snapshot", async () => {
    await open();
    // the snapshot's turn carries codex's epoch-second stamps
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
        },
      }),
    );
    expect(
      await screen.findByRole("button", { name: "这一轮的耗时" }),
    ).toHaveTextContent("7");

    act(() =>
      channel.deliver("codex", {
        seq: 5,
        method: "thread/reverted",
        params: { threadId: "thr_1", turnIds: ["turn_1"] },
      }),
    );
    await waitFor(() =>
      expect(channel.pushed.at(-1)).toMatchObject({ event: "snapshot" }),
    );
  });

  test("a message typed while a turn runs waits in the queue and goes out when it settles", async () => {
    const user = userEvent.setup();
    await open();
    act(() =>
      channel.deliver("codex", {
        seq: 4,
        method: "turn/started",
        params: { turn: { id: "turn_2", status: "inProgress" } },
      }),
    );
    await user.type(
      screen.getByRole("textbox", { name: "随心输入" }),
      "and then this{Enter}",
    );
    expect(sendMessage).not.toHaveBeenCalled();
    act(() =>
      channel.deliver("codex", {
        seq: 5,
        method: "turn/completed",
        params: { turn: { id: "turn_2", status: "completed" } },
      }),
    );
    await waitFor(() =>
      expect(sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          input: expect.objectContaining({
            threadId: "t1",
            text: "and then this",
          }),
        }),
      ),
    );
  });

  test("a sub-agent joins its own thread: its conversation nests under the parent, its approval is answered there, the plan shows", async () => {
    const user = userEvent.setup();
    await open();
    const child = "thr_1-alpha";
    act(() => {
      channel.deliverTo("thread:thr_1", "codex", {
        seq: 4,
        method: "turn/started",
        params: { turn: { id: "turn_2", status: "inProgress" } },
      });
      channel.deliverTo("thread:thr_1", "codex", {
        seq: 5,
        method: "turn/plan/updated",
        params: {
          turnId: "turn_2",
          explanation: "delegating",
          plan: [
            { step: "spawn alpha", status: "completed" },
            { step: "wait for alpha", status: "inProgress" },
          ],
        },
      });
      channel.deliverTo("thread:thr_1", "codex", {
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
        plan: null,
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
            method: "item/commandExecution/requestApproval",
            params: {
              requestId: 9,
              itemId: "cmd_alpha",
              threadId: child,
              command: "echo alpha",
            },
          },
        ],
      }),
    );
    expect(screen.getByTestId("plan")).toHaveTextContent("wait for alpha");
    const sub = screen.getByTestId("tool-subagent");
    expect(sub).toHaveTextContent("alpha");
    expect(within(sub).getByTestId("subagent-messages")).toHaveTextContent(
      "echo alpha",
    );
    expect(screen.getByTestId("turn-bar")).toHaveTextContent("等待审批");
    await user.click(screen.getAllByRole("button", { name: "允许" })[0]!);
    await waitFor(() =>
      expect(respond).toHaveBeenCalledWith(
        expect.objectContaining({
          input: { threadId: "t1", requestId: "9", decision: "accept" },
        }),
      ),
    );

    act(() => {
      channel.deliverTo(`thread:${child}`, "codex", {
        seq: 3,
        method: "serverRequest/resolved",
        params: { requestId: 9 },
      });
      channel.deliverTo(`thread:${child}`, "codex", {
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
      channel.deliverTo(`thread:${child}`, "codex", {
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
      channel.deliverTo(`thread:${child}`, "codex", {
        seq: 6,
        method: "turn/completed",
        params: { turn: { id: "turn_2-alpha", status: "completed" } },
      });
      channel.deliverTo("thread:thr_1", "codex", {
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
    // finished, the row folds like any tool; its conversation is a click away
    expect(screen.getByText("子 agent 完成")).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: /子 agent 完成/ }));
    expect(screen.getByText("done by alpha")).toBeInTheDocument();
  });

  test("the composer rail shows how full the model's context is, from codex's token usage", async () => {
    await open();
    expect(screen.queryByLabelText("上下文用量")).not.toBeInTheDocument();
    act(() =>
      channel.deliver("codex", {
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
        ],
      }),
    );
    // a mention already in the history is a chip
    const chip = await screen.findByText("lib/a.ex");
    expect(chip.closest("[data-slot=directive-text-chip]")).not.toBeNull();

    const box = screen.getByRole("textbox", { name: "随心输入" });
    await user.type(box, "look at @gat");
    // the popover asks codex's index (debounced) and lists the matches
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

  test("$ in the composer offers codex's skills; the pick is $name in the text, a chip in the message, and the SKILL.md rides on the turn", async () => {
    vi.mocked(listSkills).mockResolvedValue(
      ok([
        { name: "review-agent", description: "Review code changes", shortDescription: "review", path: "/srv/app-1/.agents/skills/review-agent/SKILL.md", enabled: true },
        { name: "docs", description: "Write the docs", shortDescription: null, path: "/srv/app-1/.agents/skills/docs/SKILL.md", enabled: true },
      ]) as never,
    );
    const user = userEvent.setup();
    const r = renderAt("/p/app-1/t/t1");
    await waitFor(() => expect(channel.topics).toContain("thread:thr_1"));
    act(() =>
      channel.reply("ok", {
        ...snapshot,
        items: [{ id: "u1", type: "userMessage", turnId: "turn_1", content: [{ type: "text", text: "use $docs here" }] }],
      }),
    );
    const chip = await screen.findByText("docs");
    expect(chip.closest("[data-slot=directive-text-chip]")).not.toBeNull();

    const box = screen.getByRole("textbox", { name: "随心输入" });
    await user.type(box, "please $rev");
    await user.click(await screen.findByRole("option", { name: /review-agent/ }));
    expect(box).toHaveValue("please $review-agent ");
    await user.type(box, "{Enter}");
    await waitFor(() =>
      expect(sendMessage).toHaveBeenCalledWith(
        expect.objectContaining({
          input: expect.objectContaining({
            text: "please $review-agent",
            skills: [{ name: "review-agent", path: "/srv/app-1/.agents/skills/review-agent/SKILL.md" }],
          }),
        }),
      ),
    );
    r.unmount();
    vi.mocked(listSkills).mockResolvedValue(ok([]) as never);
  });

  test("/ in the composer lists the commands: /review starts a review, /compact compacts, /init sends the prompt, /git opens the tool", async () => {
    const { compactThread, reviewThread } = await import("@/ash_rpc");
    const user = userEvent.setup();
    await open();
    const box = screen.getByRole("textbox", { name: "随心输入" });
    await user.type(box, "/rev");
    await user.click(await screen.findByRole("option", { name: /review/ }));
    await waitFor(() =>
      expect(reviewThread).toHaveBeenCalledWith(
        expect.objectContaining({
          input: { threadId: "t1", target: "uncommitted" },
        }),
      ),
    );
    expect(box).toHaveValue("");

    await user.type(box, "/comp");
    await user.click(await screen.findByRole("option", { name: /compact/ }));
    await waitFor(() =>
      expect(compactThread).toHaveBeenCalledWith(
        expect.objectContaining({ input: { threadId: "t1" } }),
      ),
    );

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
      channel.deliver("codex", {
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

  test("renderers: fenced code highlights with shiki, a mermaid fence is a diagram, reasoning is the step panel — open while it streams, folded after", async () => {
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
    // the turn is running and reasoning is what streams: the panel is open, its steps titled, the trigger shimmering
    const panel = document.querySelector("[data-slot=reasoning-panel]")!;
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
      channel.deliver("codex", {
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
      channel.deliver("codex", {
        seq: 5,
        method: "turn/completed",
        params: { turn: { id: "turn_1", status: "completed" } },
      });
    });
    // settled, the panel folds under its resting label; a click opens it again
    await waitFor(() =>
      expect(
        document.querySelector("[data-slot=reasoning-panel]"),
      ).toHaveAttribute("data-state", "closed"),
    );
    await userEvent.click(screen.getByRole("button", { name: /思考过程/ }));
    await waitFor(() =>
      expect(
        document.querySelector("[data-slot=reasoning-panel]"),
      ).toHaveAttribute("data-state", "open"),
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

  test("phone: the chat still shows the command block and the bottom toolbar", async () => {
    setViewport(390);
    await open();
    expect(screen.getByTestId("bottom-toolbar")).toBeInTheDocument();
    expect(
      within(screen.getByTestId("chat-area")).getByTestId("tool-command"),
    ).toBeInTheDocument();
  });

  test("a thread that no longer exists (a stale link) says so and offers a new chat", async () => {
    const user = userEvent.setup();
    const { router } = renderAt("/p/app-1/t/gone");
    await screen.findByText("找不到这个会话");
    await user.click(screen.getByRole("link", { name: "新会话" }));
    await waitFor(() => expect(router.state.location.pathname).toBe("/p/app-1"));
  });
});
