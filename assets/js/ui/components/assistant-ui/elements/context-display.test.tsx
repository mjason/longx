import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, test } from "vitest";
import { ContextDisplay } from "./context-display";

const usage = { totalTokens: 12_000, inputTokens: 10_000, cachedInputTokens: 2_000, outputTokens: 1_500, reasoningTokens: 500 };

describe("ContextDisplay.Ring", () => {
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
