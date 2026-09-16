import { AssistantRuntimeProvider, useLocalRuntime, type ChatModelAdapter } from "@assistant-ui/react-native";
import { fireEvent, render, screen } from "@testing-library/react-native";
import type { ReactNode } from "react";
import { CodexTool } from "./CodexTool";

const adapter: ChatModelAdapter = { async *run() {} };

function Runtime({ children }: { children: ReactNode }) {
  const runtime = useLocalRuntime(adapter);
  return <AssistantRuntimeProvider runtime={runtime}>{children}</AssistantRuntimeProvider>;
}

const base = { type: "tool-call" as const, toolCallId: "c1", argsText: "", status: { type: "complete" as const, reason: "stop" as const }, addResult: () => {}, resume: () => {}, respondToApproval: jest.fn(async () => {}) };

describe("CodexTool", () => {
  test("a command: the verb, the command chip, the output and a non-zero exit", async () => {
    await render(
      <Runtime>
        <CodexTool {...base} toolName="commandExecution" args={{ command: "ls -la" }} result={{ status: "completed", exitCode: 2, output: "a\nb\n" }} isError />
      </Runtime>,
    );
    expect(screen.getByText("运行了")).toBeTruthy();
    expect(screen.getByText("ls -la")).toBeTruthy();
    // failed: open by default, the output shown
    expect(screen.getByTestId("command-output").props.children).toBe("a\nb\n");
    expect(screen.getByText("退出码 2")).toBeTruthy();
  });

  test("a pending approval is the approval card; a choice answers with the option's id", async () => {
    const respond = jest.fn(async () => {});
    await render(
      <Runtime>
        <CodexTool
          {...base}
          toolName="commandExecution"
          args={{ command: "rm -rf build" }}
          status={{ type: "requires-action", reason: "interrupt" }}
          respondToApproval={respond}
          {...({ approval: { id: "7", prompt: "codex 想运行这条命令", display: "select", options: [{ id: "accept", label: "本轮允许" }, { id: "accept_for_session", label: "本会话允许" }, { id: "decline", label: "拒绝" }] } } as object)}
        />
      </Runtime>,
    );
    expect(screen.getByText("需要你的批准")).toBeTruthy();
    await fireEvent.press(screen.getByText("Allow once"));
    expect(respond).toHaveBeenCalledWith({ optionId: "accept" });
    await fireEvent.press(screen.getByText("Deny"));
    expect(respond).toHaveBeenCalledWith({ optionId: "decline" });
  });

  test("a file change lists its files; a search its query; an unknown tool its name", async () => {
    await render(
      <Runtime>
        <CodexTool {...base} toolName="fileChange" args={{ changes: [{ path: "lib/a.ex", kind: "update" }, { path: "lib/b.ex", kind: "add" }] }} result={{ status: "completed" }} />
        <CodexTool {...base} toolName="webSearch" args={{ query: "elixir agents" }} result={{ results: [] }} />
        <CodexTool {...base} toolName="memory.note" args={{ note: "tabs" }} result={{ success: true }} />
      </Runtime>,
    );
    expect(screen.getByText("修改了文件")).toBeTruthy();
    expect(screen.getByText("2 个文件")).toBeTruthy();
    expect(screen.getByText("搜索了")).toBeTruthy();
    expect(screen.getByText("elixir agents")).toBeTruthy();
    expect(screen.getByText("调用了 memory.note")).toBeTruthy();
  });
});
