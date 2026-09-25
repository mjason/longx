import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, test, vi } from "vitest";
import { StoppedTurnView } from "./StoppedTurn";
import { WaitingMessagesView } from "./WaitingMessages";

const at = "2026-09-25T01:00:00Z";

describe("what arrives from elsewhere while a turn runs", () => {
  test("it is listed above the composer, never put in it: who sent it, what it is, and 立即插入", () => {
    const onRelease = vi.fn();
    render(
      <WaitingMessagesView
        waiting={{
          items: [
            { id: "w1", text: "tests pass", from: "coder", kind: "report", at },
            { id: "w2", text: "[job quick] finished with exit code 2 after 3 s.\nCommand: `exit 2`", source: "job:quick", at },
            { id: "w3", text: "what is left?", from: "~abc123", kind: "question", question: true, at },
          ],
          paused: false,
        }}
        onRelease={onRelease}
      />,
    );
    expect(screen.getByTestId("waiting-messages")).toHaveTextContent("本轮结束后处理");
    const rows = screen.getAllByTestId("waiting-message");
    expect(rows).toHaveLength(3);
    expect(rows[0]).toHaveTextContent("coder");
    expect(rows[0]).toHaveTextContent("汇报");
    expect(rows[0]).toHaveTextContent("tests pass");
    expect(rows[1]).toHaveTextContent("后台任务 quick");
    expect(rows[1]).toHaveTextContent("[job quick] finished with exit code 2 after 3 s.");
    expect(rows[1]).not.toHaveTextContent("Command:");
    expect(rows[2]).toHaveTextContent("提问");
    fireEvent.click(rows[0]!.querySelector("button")!);
    expect(onRelease).toHaveBeenCalledWith("w1");
  });

  test("after the person's stop it says it waits for them; nothing waiting, nothing drawn", () => {
    const { rerender } = render(
      <WaitingMessagesView waiting={{ items: [{ id: "w1", text: "tests pass", from: "coder", at }], paused: true }} onRelease={() => {}} />,
    );
    expect(screen.getByTestId("waiting-messages")).toHaveTextContent("你停止了这一轮，这些消息等你继续再处理");
    rerender(<WaitingMessagesView waiting={{ items: [], paused: true }} onRelease={() => {}} />);
    expect(screen.queryByTestId("waiting-messages")).toBeNull();
  });
});

describe("a stopped turn (assistant-ui's stopped-run element)", () => {
  test("stopped by the person: 继续 and, for a turn of theirs that ran nothing, 丢弃", () => {
    const onContinue = vi.fn();
    const onDiscard = vi.fn();
    render(<StoppedTurnView byPerson onContinue={onContinue} onDiscard={onDiscard} />);
    const card = screen.getByTestId("stopped-turn");
    expect(card).toHaveTextContent("你停止了这一轮");
    fireEvent.click(screen.getByRole("button", { name: /继续/ }));
    fireEvent.click(screen.getByRole("button", { name: "丢弃" }));
    expect(onContinue).toHaveBeenCalled();
    expect(onDiscard).toHaveBeenCalled();
  });

  test("stopped by Longx's watchdog: says so; no 丢弃 without a handler", () => {
    render(<StoppedTurnView byPerson={false} onContinue={() => {}} />);
    expect(screen.getByTestId("stopped-turn")).toHaveTextContent("长时间没有进展，Longx 停止了这一轮");
    expect(screen.queryByRole("button", { name: "丢弃" })).toBeNull();
  });
});
