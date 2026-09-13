import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, test, vi } from "vitest";
import type { ToolCallMessagePartProps } from "@assistant-ui/react";
import { CommandExecutionTool, FileChangeTool, QuestionsTool, WebSearchTool, parseDiff, treeOf } from "./toolkit";

const answerRequest = vi.fn(async () => {});
vi.mock("@assistant-ui/react", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@assistant-ui/react")>();
  return { ...mod, useAuiState: (selector: (s: unknown) => unknown) => selector({ thread: { extras: { answerRequest } } }) };
});

// A tool-call part as assistant-ui hands it to a renderer (the parts we read).
// eslint-disable-next-line @typescript-eslint/no-explicit-any
function part(over: Partial<ToolCallMessagePartProps>): any {
  return {
    type: "tool-call",
    toolCallId: "c1",
    toolName: "commandExecution",
    args: {},
    argsText: "{}",
    result: undefined,
    isError: undefined,
    status: { type: "running" },
    addResult: () => {},
    resume: () => {},
    respondToApproval: async () => {},
    ...over,
  } as ToolCallMessagePartProps;
}

const APPROVAL = {
  id: "42",
  prompt: "允许执行这条命令？",
  display: "select" as const,
  options: [
    { id: "accept", kind: "allow-once" as const, label: "允许" },
    { id: "accept_for_session", kind: "allow-always" as const, label: "本会话都允许" },
    { id: "decline", kind: "reject-once" as const, label: "拒绝" },
  ],
};

describe("CommandExecutionTool", () => {
  test("streams output while running (row open), collapses to a row with the exit code when done", () => {
    const { rerender } = render(
      <CommandExecutionTool {...part({ args: { command: "mix test", cwd: "/p" }, artifact: "line 1\nline 2" })} />,
    );
    expect(screen.getAllByText("mix test").length).toBeGreaterThan(0);
    expect(screen.getByText("line 2")).toBeInTheDocument();

    rerender(
      <CommandExecutionTool
        {...part({
          args: { command: "mix test", cwd: "/p" },
          status: { type: "complete" },
          result: { status: "completed", exitCode: 3, output: "boom", durationMs: 10 },
          isError: true,
        })}
      />,
    );
    // a failed command stays open
    expect(screen.getByText("exit 3")).toBeInTheDocument();
    expect(screen.getByText("boom")).toBeInTheDocument();

    rerender(
      <CommandExecutionTool
        {...part({ args: { command: "mix test", cwd: "/p" }, status: { type: "complete" }, result: { status: "completed", exitCode: 0, output: "ok", durationMs: 10 } })} />,
    );
    // a successful one collapses to its row: the verb, the command, a check; the output is behind the disclosure
    expect(screen.getByRole("button", { name: /运行了/ })).toBeInTheDocument();
    expect(screen.queryByText("ok")).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: /运行了/ }));
    expect(screen.getByText("ok")).toBeInTheDocument();
    expect(screen.getByText("exit 0")).toBeInTheDocument();
  });

  test("a pending approval offers allow / allow-for-session / deny and answers with the option id", async () => {
    const respondToApproval = vi.fn(async () => {});
    render(
      <CommandExecutionTool
        {...part({ args: { command: "rm -rf build", cwd: "/p" }, status: { type: "requires-action", reason: "interrupt" }, approval: APPROVAL, respondToApproval })}
      />,
    );
    expect(screen.getByText("允许执行这条命令？")).toBeInTheDocument();
    expect(screen.getAllByText("rm -rf build").length).toBeGreaterThan(0);
    fireEvent.click(screen.getByRole("button", { name: "本会话都允许" }));
    expect(respondToApproval).toHaveBeenCalledWith({ optionId: "accept_for_session" });
    // one answer per request: the buttons go dead once one is sent
    fireEvent.click(screen.getByRole("button", { name: "拒绝" }));
    expect(respondToApproval).toHaveBeenCalledTimes(1);
  });

  test("a declined command says so instead of an exit code", () => {
    render(
      <CommandExecutionTool
        {...part({ args: { command: "rm -rf /", cwd: "/p" }, status: { type: "complete" }, result: { status: "declined", exitCode: null, output: "" }, isError: true })}
      />,
    );
    expect(screen.getByText("已拒绝")).toBeInTheDocument();
  });
});

describe("FileChangeTool", () => {
  const changes = [
    { path: "lib/a.ex", kind: { type: "update" }, diff: "@@ -1,2 +1,2 @@\n-old\n+new\n same\n" },
    { path: "lib/b.ex", kind: { type: "add" }, diff: "@@ -0,0 +1 @@\n+hello\n" },
  ];

  test("parseDiff classifies lines and counts +/-", () => {
    const parsed = parseDiff("--- a\n+++ b\n@@ -1,2 +1,2 @@\n-old\n+new\n same\n");
    expect(parsed.lines.map((l) => l.kind)).toEqual(["context", "removed", "added", "context"]);
    expect(parsed).toMatchObject({ additions: 1, deletions: 1 });
  });

  test("a row per change set: the file tree and one diff per file behind the disclosure", () => {
    render(<FileChangeTool {...part({ toolName: "fileChange", args: { changes }, status: { type: "complete" }, result: { status: "completed", output: "" } })} />);
    fireEvent.click(screen.getByRole("button", { name: /修改了/ }));
    expect(screen.getAllByText("2 个文件改动").length).toBeGreaterThan(0);
    expect(screen.getByText("lib/a.ex")).toBeInTheDocument();
    expect(screen.getByText("+ lib/b.ex")).toBeInTheDocument();
    expect(screen.getByText("new")).toBeInTheDocument();
    // the tree groups by folder
    expect(screen.getByText("lib")).toBeInTheDocument();
  });

  test("treeOf builds folder nodes above their files, sorted", () => {
    const nodes = treeOf([
      { path: "lib/b.ex", additions: 1, deletions: 0 },
      { path: "lib/a.ex", additions: 1, deletions: 1 },
      { path: "README.md", additions: 2, deletions: 0 },
    ]);
    expect(nodes.map((n) => `${n.kind}:${n.path}@${n.depth}`)).toEqual(["folder:lib@0", "file:lib/a.ex@1", "file:lib/b.ex@1", "file:README.md@0"]);
  });

  test("a pending approval lists the files and answers", () => {
    const respondToApproval = vi.fn(async () => {});
    render(
      <FileChangeTool
        {...part({ toolName: "fileChange", args: { changes }, status: { type: "requires-action", reason: "interrupt" }, approval: { ...APPROVAL, prompt: "允许修改这些文件？" }, respondToApproval })}
      />,
    );
    expect(screen.getByText("允许修改这些文件？")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "允许" }));
    expect(respondToApproval).toHaveBeenCalledWith({ optionId: "accept" });
  });
});

describe("QuestionsTool", () => {
  test("renders codex's questions, answers through the runtime's extras", () => {
    render(
      <QuestionsTool
        {...part({
          toolName: "requestUserInput",
          status: { type: "requires-action", reason: "interrupt" },
          args: {
            requestId: "3",
            questions: [
              { id: "q1", header: "DB", question: "which db?", options: [{ label: "sqlite", description: "small" }, { label: "postgres", description: "" }], isOther: true },
              { id: "q2", header: "Name", question: "project name?", options: null },
            ],
          },
        })}
      />,
    );
    fireEvent.click(screen.getByRole("button", { name: "sqlite" }));
    fireEvent.change(screen.getByRole("textbox", { name: "project name?" }), { target: { value: "longx" } });
    fireEvent.click(screen.getByRole("button", { name: "发送" }));
    expect(answerRequest).toHaveBeenCalledWith("3", { q1: ["sqlite"], q2: ["longx"] });
  });
});

describe("WebSearchTool", () => {
  test("an openPage action reads as a fetch, not a search", () => {
    render(
      <WebSearchTool
        {...part({
          toolName: "webSearch",
          args: { query: "https://x.dev/docs", action: { type: "openPage", url: "https://x.dev/docs" } },
          status: { type: "complete" },
          result: { results: [{ type: "open", url: "https://x.dev/docs", title: "Docs" }] },
        })}
      />,
    );
    expect(screen.getByRole("button", { name: /读取了/ })).toBeInTheDocument();
    expect(screen.queryByText(/搜索了/)).not.toBeInTheDocument();
  });

  test("shows the query, then the sources as links", () => {
    const { rerender } = render(<WebSearchTool {...part({ toolName: "webSearch", args: { query: "elixir 1.19" } })} />);
    expect(screen.getAllByText("elixir 1.19").length).toBeGreaterThan(0);
    expect(screen.getAllByText("搜索中…").length).toBeGreaterThan(0);
    rerender(
      <WebSearchTool
        {...part({
          toolName: "webSearch",
          args: { query: "elixir 1.19" },
          status: { type: "complete" },
          result: { results: [{ title: "Elixir 1.19 released", url: "https://elixir-lang.org/blog/1-19" }] },
        })}
      />,
    );
    fireEvent.click(screen.getByRole("button", { name: /搜索了/ }));
    expect(screen.getByText("读了 1 个来源")).toBeInTheDocument();
    expect(screen.getByRole("link", { name: /Elixir 1.19 released/ })).toHaveAttribute("href", "https://elixir-lang.org/blog/1-19");
  });
});

describe("agents", () => {
  test("a sub-agent row shows its state, nests its conversation and lifts the child's approval to the parent", async () => {
    const { CollabTool, SubagentTool } = await import("./toolkit");
    const respondToApproval = vi.fn(async () => {});
    const { rerender } = render(
      <SubagentTool {...part({ toolName: "subagent", toolCallId: "child-alpha", args: { name: "alpha", path: "/root/alpha", threadId: "child-alpha", kind: "started", request: null } })} />,
    );
    expect(screen.getByTestId("tool-subagent")).toHaveTextContent("alpha");
    expect(screen.getByText("子 agent 工作中")).toBeInTheDocument();

    rerender(
      <SubagentTool
        {...part({
          toolName: "subagent",
          toolCallId: "child-alpha",
          args: { name: "alpha", path: "/root/alpha", threadId: "child-alpha", kind: "started", request: { command: "rm -rf x" } },
          approval: { ...APPROVAL, id: "7", prompt: "子 agent alpha：允许执行这条命令？" },
          status: { type: "requires-action", reason: "interrupt" },
          respondToApproval,
        })}
      />,
    );
    expect(screen.getByText("子 agent alpha：允许执行这条命令？")).toBeInTheDocument();
    expect(screen.getByText("rm -rf x")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "允许" }));
    expect(respondToApproval).toHaveBeenCalledWith({ optionId: "accept" });

    rerender(
      <SubagentTool {...part({ toolName: "subagent", toolCallId: "child-alpha", args: { name: "alpha", path: "/root/alpha", threadId: "child-alpha", kind: "completed", request: null }, result: { kind: "completed" }, status: { type: "complete" } })} />,
    );
    expect(screen.getByText("子 agent 完成")).toBeInTheDocument();

    // collaboration: waiting lists the agents with their reported states; a spawn is a handoff
    render(
      <CollabTool
        {...part({
          toolName: "collab",
          toolCallId: "collab1",
          args: { tool: "wait", prompt: null, model: null, agents: [{ threadId: "child-alpha", name: "alpha" }, { threadId: "child-beta", name: "beta" }] },
          result: { status: "completed", agentsStates: { "child-alpha": { status: "completed", message: "done" }, "child-beta": { status: "running", message: null } } },
          status: { type: "complete" },
        })}
      />,
    );
    expect(screen.getByTestId("tool-collab")).toHaveTextContent("等到了");
    fireEvent.click(screen.getByRole("button", { name: /等到了/ }));
    expect(screen.getByRole("progressbar", { name: "alpha progress" })).toHaveAttribute("aria-valuenow", "100");
    expect(screen.getByRole("progressbar", { name: "beta progress" })).not.toHaveAttribute("aria-valuenow");

    render(<CollabTool {...part({ toolName: "collab", toolCallId: "spawn1", args: { tool: "spawnAgent", prompt: "read the docs", model: "deepseek-flash", agents: [] } })} />);
    expect(screen.getByText("正在派出")).toBeInTheDocument();
    expect(screen.getByText("read the docs")).toBeInTheDocument();
    expect(screen.getAllByText("新 agent").length).toBeGreaterThan(0);
  });

  test("the plan renders codex's step states, not a running index", async () => {
    const { PlanView } = await import("./toolkit");
    render(<PlanView explanation="delegating" steps={[{ step: "spawn", status: "completed" }, { step: "wait", status: "inProgress" }, { step: "report", status: "pending" }]} />);
    expect(screen.getByText("计划")).toBeInTheDocument();
    expect(screen.getByText("1 / 3")).toBeInTheDocument();
    expect(screen.getByText("delegating")).toBeInTheDocument();
    expect(screen.getByText("wait")).toHaveClass("text-foreground/90");
  });
});
