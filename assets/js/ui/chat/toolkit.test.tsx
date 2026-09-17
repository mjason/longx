import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, test, vi } from "vitest";
import type { ToolCallMessagePartProps } from "@assistant-ui/react";
import { ActionAnswerContext, ActionTool, CommandExecutionTool, FileChangeTool, SubagentTool, WebSearchTool, parseDiff, treeOf } from "./toolkit";

const answerAction = vi.fn(async () => {});

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
});

describe("ActionTool", () => {
  test("a tool's ask: the link, the fields, answered through the runtime's extras; 取消 answers too", () => {
    answerAction.mockClear();
    render(
      <ActionAnswerContext.Provider value={answerAction}>
        <ActionTool
          {...part({
            toolName: "action",
            toolCallId: "call_3:ask",
            status: { type: "requires-action", reason: "interrupt" },
            args: { requestId: "3", title: "登录 GitHub", text: "打开链接完成登录后填入验证码", url: "https://x.dev/login", fields: [{ id: "code", label: "验证码" }] },
          })}
        />
      </ActionAnswerContext.Provider>,
    );
    expect(screen.getByRole("link", { name: "打开链接" })).toHaveAttribute("href", "https://x.dev/login");
    expect(screen.getByText("打开链接完成登录后填入验证码")).toBeInTheDocument();
    fireEvent.change(screen.getByRole("textbox", { name: "验证码" }), { target: { value: "1234" } });
    fireEvent.click(screen.getByRole("button", { name: "发送" }));
    expect(answerAction).toHaveBeenCalledWith("3", { code: "1234" });

    answerAction.mockClear();
    render(
      <ActionAnswerContext.Provider value={answerAction}>
        <ActionTool {...part({ toolName: "action", toolCallId: "call_4:ask", status: { type: "requires-action", reason: "interrupt" }, args: { requestId: "4", title: "去登录", text: "", url: null, fields: [] } })} />
      </ActionAnswerContext.Provider>,
    );
    fireEvent.click(screen.getByRole("button", { name: "已完成" }));
    expect(answerAction).toHaveBeenCalledWith("4", { done: true });
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
  test("a sub-agent row shows its state, says when the child waits on the person, and nests its conversation", () => {
    const { rerender } = render(
      <SubagentTool {...part({ toolName: "subagent", toolCallId: "child-alpha", args: { name: "alpha", path: "/root/alpha", threadId: "child-alpha", kind: "started", request: null } })} />,
    );
    expect(screen.getByTestId("tool-subagent")).toHaveTextContent("alpha");
    expect(screen.getByText("子 agent 工作中")).toBeInTheDocument();

    rerender(
      <SubagentTool
        {...part({ toolName: "subagent", toolCallId: "child-alpha", args: { name: "alpha", path: "/root/alpha", threadId: "child-alpha", kind: "started", request: { title: "登录 GitHub" } } })}
      />,
    );
    expect(screen.getByText("登录 GitHub")).toBeInTheDocument();

    rerender(
      <SubagentTool {...part({ toolName: "subagent", toolCallId: "child-alpha", args: { name: "alpha", path: "/root/alpha", threadId: "child-alpha", kind: "completed", request: null }, result: { kind: "completed" }, status: { type: "complete" } })} />,
    );
    expect(screen.getByText("子 agent 完成")).toBeInTheDocument();
  });

  test("a context compaction is a quiet marker", async () => {
    const { CompactionView } = await import("./toolkit");
    render(<CompactionView />);
    expect(screen.getByRole("separator")).toHaveTextContent("上下文已压缩");
  });
});
