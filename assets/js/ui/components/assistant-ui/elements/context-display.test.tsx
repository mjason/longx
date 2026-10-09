import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, test } from "vitest";
import { ContextDisplay } from "./context-display";

const usage = { totalTokens: 12_000, inputTokens: 10_000, cachedInputTokens: 2_000, outputTokens: 1_500, reasoningTokens: 500 };

describe("ContextDisplay.Ring", () => {
  test("a compacted context clears the old full ring until measured again, including zero", () => {
    const { rerender } = render(<ContextDisplay.Ring modelContextWindow={100000} usage={{ totalTokens: 100000 }} />);
    expect(screen.getByRole("button")).toHaveTextContent("100%");
    rerender(<ContextDisplay.Ring modelContextWindow={100000} usage={{ totalTokens: 0, pending: true }} labels={{ trigger: "上下文用量", pending: "上下文已压缩，等待更新 token 用量", full: (p) => `已用 ${p}%`, input: "输入", cachedInput: "缓存", output: "输出", reasoning: "思考" }} />);
    expect(screen.getByRole("button")).toHaveTextContent("—");
    expect(screen.queryByText("100%")).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button"));
    expect(screen.getByText("上下文已压缩，等待更新 token 用量")).toBeInTheDocument();
    rerender(<ContextDisplay.Ring modelContextWindow={100000} usage={{ pending: true }} />);
    expect(screen.getByText("Context compacted; awaiting updated token usage")).toBeInTheDocument();
    rerender(<ContextDisplay.Ring modelContextWindow={100000} usage={{ totalTokens: 12000 }} />);
    expect(screen.getByRole("button")).toHaveTextContent("12%");
    rerender(<ContextDisplay.Ring modelContextWindow={100000} usage={{ totalTokens: 0 }} />);
    expect(screen.getByRole("button")).toHaveTextContent("0%");
  });

  test("opens on click and survives the thread scrolling under it (streaming output auto-scrolls the viewport the composer sits in)", () => {
    render(
      <div data-testid="viewport" style={{ overflow: "auto" }}>
        <ContextDisplay.Ring modelContextWindow={100_000} usage={usage} resetKey="t" labels={{ trigger: "上下文用量", full: (p) => `已用 ${p}%`, input: "输入", cachedInput: "缓存", output: "输出", reasoning: "思考" }} />
      </div>,
    );
    expect(screen.queryByText("已用 12%")).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button"));
    expect(screen.getByText("已用 12%")).toBeInTheDocument();
    expect(screen.getByText("输入")).toBeInTheDocument();

    fireEvent.scroll(screen.getByTestId("viewport"));
    expect(screen.getByText("已用 12%")).toBeInTheDocument();
  });
});
