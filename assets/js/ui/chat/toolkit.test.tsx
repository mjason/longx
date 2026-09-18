import { fireEvent, render, screen, within } from "@testing-library/react";
import { describe, expect, test, vi } from "vitest";
import type { ToolCallMessagePartProps } from "@assistant-ui/react";
import { ActionAnswerContext, ActionTool, CommandExecutionTool, FileChangeTool, PresentTool, SendFileTool, ShowDiffTool, ShowFileTool, ShowHtmlTool, SubagentTool, SurfaceContext, WebSearchTool, parseDiff, treeOf } from "./toolkit";

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

  test("hovering the (truncated) command chip shows the whole command and its directory in a floating card", async () => {
    const user = (await import("@testing-library/user-event")).default.setup();
    const long = "cd /home/mj/dev/python/jbt_lab && rm -rf .patchtest_tmp /tmp/patchtest && rm -f /home/mj/dev/python/jbt_lab/.longx/local/knowledge/x.md && echo ok";
    render(
      <CommandExecutionTool
        {...part({ args: { command: long, cwd: "/home/mj/dev/python/jbt_lab" }, status: { type: "complete" }, result: { status: "completed", exitCode: 0, output: "ok", durationMs: 10 } })}
      />,
    );
    const chip = screen.getByTestId("tool-call-query");
    expect(chip).not.toHaveAttribute("title");
    await user.hover(chip);
    const card = await screen.findByRole("tooltip");
    expect(card).toHaveTextContent(long);
    expect(card).toHaveTextContent("/home/mj/dev/python/jbt_lab");
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

describe("PresentTool", () => {
  test("draws the model's tree from the vocabulary: a card with facts, a table, markdown with a code fence", () => {
    render(
      <PresentTool
        {...part({
          toolName: "longx.present",
          status: { type: "complete" },
          args: {
            $type: "Card",
            title: "Q3 收入",
            children: [
              { $type: "Row", children: [{ $type: "Fact", label: "Bookings", value: "$1.2M" }, { $type: "Fact", label: "Growth", value: "+18%" }] },
              { $type: "Table", columns: [{ label: "名称" }, { label: "数量" }], rows: [["a", 1], ["b", 2]] },
              { $type: "Markdown", value: "```elixir\nIO.puts(1)\n```" },
            ],
          },
          result: { success: true, contentItems: [{ type: "inputText", text: "shown to the user" }] },
        })}
      />,
    );
    expect(screen.getByText("Q3 收入")).toBeInTheDocument();
    expect(screen.getByText("Bookings")).toBeInTheDocument();
    expect(screen.getByText("$1.2M")).toBeInTheDocument();
    expect(screen.getByRole("columnheader", { name: "名称" })).toBeInTheDocument();
    expect(screen.getByRole("cell", { name: "b" })).toBeInTheDocument();
    expect(screen.getByText("IO.puts(1)")).toBeInTheDocument();
  });

  test("an unknown component draws nothing but does not crash; a streaming call shows a placeholder", () => {
    render(<PresentTool {...part({ toolName: "longx.present", status: { type: "running" }, args: { $type: "Rocket" } })} />);
    expect(screen.getByTestId("tool-present")).toBeInTheDocument();
  });
});

describe("ActionTool", () => {
  test("an optional field (required: false) may stay empty: 发送 is enabled and the empty value is sent", () => {
    answerAction.mockClear();
    render(
      <ActionAnswerContext.Provider value={answerAction}>
        <ActionTool
          {...part({
            toolName: "action",
            toolCallId: "call_3b:ask",
            status: { type: "requires-action", reason: "interrupt" },
            args: { requestId: "3b", title: "输入凭证 coros 的密钥", text: "", url: null, fields: [{ id: "client_secret", label: "Client Secret（公开客户端留空）", secret: true, required: false }] },
          })}
        />
      </ActionAnswerContext.Provider>,
    );
    expect(screen.getByRole("button", { name: "发送" })).toBeEnabled();
    fireEvent.click(screen.getByRole("button", { name: "发送" }));
    expect(answerAction).toHaveBeenCalledWith("3b", { client_secret: "" });
  });

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

  test("an ask that carries a generative tree draws it; what the person fires answers as the action", () => {
    answerAction.mockClear();
    render(
      <ActionAnswerContext.Provider value={answerAction}>
        <ActionTool
          {...part({
            toolName: "action",
            toolCallId: "call_5:ask",
            status: { type: "requires-action", reason: "interrupt" },
            args: {
              requestId: "5",
              title: "选一个环境",
              text: "",
              url: null,
              fields: [],
              spec: {
                $type: "Card",
                title: "选一个环境",
                asForm: true,
                confirm: { label: "就这个", $action: { type: "pick" } },
                cancel: { label: "算了", $action: { type: "dismiss" } },
                children: [{ $type: "Select", name: "env", options: [{ label: "预发", value: "staging" }, { label: "生产", value: "prod" }] }],
              },
            },
          })}
        />
      </ActionAnswerContext.Provider>,
    );
    // the vocabulary's form, not the elicitation fields
    expect(screen.queryByRole("button", { name: "已完成" })).not.toBeInTheDocument();
    fireEvent.change(screen.getByRole("combobox"), { target: { value: "prod" } });
    fireEvent.click(screen.getByRole("button", { name: "就这个" }));
    expect(answerAction).toHaveBeenCalledWith("5", { action: { type: "pick", $input: { env: "prod" } } });

    // a cancel is the person's answer too — the model reads that they dismissed it
    answerAction.mockClear();
    render(
      <ActionAnswerContext.Provider value={answerAction}>
        <ActionTool
          {...part({
            toolName: "action",
            toolCallId: "call_6:ask",
            status: { type: "requires-action", reason: "interrupt" },
            args: { requestId: "6", title: "", text: "", url: null, fields: [], spec: { $type: "Button", label: "继续", $action: { type: "go" } } },
          })}
        />
      </ActionAnswerContext.Provider>,
    );
    fireEvent.click(screen.getByRole("button", { name: "继续" }));
    expect(answerAction).toHaveBeenCalledWith("6", { action: { type: "go" } });
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

describe("surfaces: files and artifacts for the person", () => {
  const open = vi.fn();
  const surface = { projectId: "p1", open };
  const done = (toolName: string, args: Record<string, unknown>, details: Record<string, unknown>) =>
    part({ toolName, args, status: { type: "complete" }, result: { success: true, contentItems: [], details } });

  test("show_file is a row naming the file and line; 打开 opens the editor tab", () => {
    render(
      <SurfaceContext.Provider value={surface}>
        <ShowFileTool {...done("longx.show_file", { path: "lib/a.ex", line: 12 }, { path: "lib/a.ex", line: 12 })} />
      </SurfaceContext.Provider>,
    );
    expect(screen.getByTestId("tool-show-file")).toHaveTextContent("lib/a.ex:12");
    fireEvent.click(screen.getByRole("button", { name: "打开" }));
    expect(open).toHaveBeenCalledWith({ kind: "file", path: "lib/a.ex", line: 12 });
  });

  test("show_diff opens the diff tab of the file (a commit when one was named)", () => {
    render(
      <SurfaceContext.Provider value={surface}>
        <ShowDiffTool {...done("longx.show_diff", { path: "a.ex", sha: "abc1234" }, { path: "lib/a.ex", sha: "abc1234" })} />
      </SurfaceContext.Provider>,
    );
    expect(screen.getByTestId("tool-show-diff")).toHaveTextContent("lib/a.ex");
    expect(screen.getByTestId("tool-show-diff")).toHaveTextContent("abc1234");
    fireEvent.click(screen.getByRole("button", { name: "打开" }));
    expect(open).toHaveBeenCalledWith({ kind: "diff", path: "lib/a.ex", sha: "abc1234" });
  });

  test("send_file is a download card: name, size, a link into /files; an image is drawn inline", () => {
    render(
      <SurfaceContext.Provider value={surface}>
        <SendFileTool {...done("longx.send_file", { path: "out/报表.csv" }, { path: "out/报表.csv", name: "报表.csv", bytes: 2048, mime: "text/csv", attachment: false, title: "结果" })} />
        <SendFileTool {...done("longx.send_file", { path: "/att/x.png" }, { path: "20260918T010203-x.png", name: "x.png", bytes: 10, mime: "image/png", attachment: true, title: null })} />
      </SurfaceContext.Provider>,
    );
    const cards = screen.getAllByTestId("tool-send-file");
    expect(cards[0]).toHaveTextContent("结果");
    expect(cards[0]).toHaveTextContent("报表.csv");
    expect(cards[0]).toHaveTextContent("2.0 KB");
    const link = within(cards[0]!).getByRole("link", { name: /下载/ });
    expect(link).toHaveAttribute("href", "/files/p1/out/%E6%8A%A5%E8%A1%A8.csv");
    expect(link).toHaveAttribute("download");
    const img = within(cards[1]!).getByRole("img");
    expect(img).toHaveAttribute("src", "/files/p1/_attachments/20260918T010203-x.png?inline=1");
  });

  test("show_html is an artifact row: the title, 打开 opens the artifact tab with the html (or the url)", () => {
    render(
      <SurfaceContext.Provider value={surface}>
        <ShowHtmlTool {...done("longx.show_html", { title: "销量图", html: "<h1>hi</h1>" }, { kind: "html", title: "销量图", bytes: 11 })} />
        <ShowHtmlTool {...done("longx.show_html", { title: "站点", url: "https://example.com/" }, { kind: "url", title: "站点", url: "https://example.com/" })} />
      </SurfaceContext.Provider>,
    );
    const rows = screen.getAllByTestId("tool-show-html");
    expect(rows[0]).toHaveTextContent("销量图");
    fireEvent.click(within(rows[0]!).getByRole("button", { name: "打开" }));
    expect(open).toHaveBeenLastCalledWith({ kind: "artifact", id: "c1", title: "销量图", html: "<h1>hi</h1>" });
    fireEvent.click(within(rows[1]!).getByRole("button", { name: "打开" }));
    expect(open).toHaveBeenLastCalledWith({ kind: "artifact", id: "c1", title: "站点", url: "https://example.com/" });
  });

  test("outside a project window (no surface context) the rows still name the thing, without a button", () => {
    render(<ShowFileTool {...done("longx.show_file", { path: "a.ex" }, { path: "a.ex", line: null })} />);
    expect(screen.getByTestId("tool-show-file")).toHaveTextContent("a.ex");
    expect(screen.queryByRole("button", { name: "打开" })).not.toBeInTheDocument();
  });
});
