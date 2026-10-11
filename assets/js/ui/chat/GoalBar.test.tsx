import { fireEvent, render, screen, within } from "@testing-library/react";
import { expect, test, vi } from "vitest";
import { GoalProvider, useGoalDialog } from "./GoalBar";

const { mutate } = vi.hoisted(() => ({ mutate: vi.fn() }));
vi.mock("@/core/projects", () => ({
  useGoalActions: (threadId: string) => ({
    set: { mutate: (input: unknown) => mutate(threadId, input), isPending: false },
    clear: { mutate: vi.fn(), isPending: false },
  }),
}));

function OpenGoal() {
  const dialog = useGoalDialog();
  return <button onClick={dialog?.open}>open goal</button>;
}

test("an open goal draft cannot follow the provider to another cached session", () => {
  const { rerender } = render(<GoalProvider threadId="A" goal={null}><OpenGoal /></GoalProvider>);
  fireEvent.click(screen.getByText("open goal"));
  fireEvent.change(within(screen.getByRole("dialog")).getByLabelText("目标"), {
    target: { value: "A private draft" },
  });

  // Preserve the same provider instance, as switching cached runtimes does.
  rerender(<GoalProvider threadId="B" goal={null}><OpenGoal /></GoalProvider>);
  expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  expect(mutate).not.toHaveBeenCalled();
  fireEvent.click(screen.getByText("open goal"));
  const dialog = screen.getByRole("dialog");
  expect(within(dialog).getByLabelText("目标")).toHaveValue("");
  fireEvent.change(within(dialog).getByLabelText("目标"), { target: { value: "B goal" } });
  fireEvent.click(within(dialog).getByRole("button", { name: "保存" }));
  expect(mutate).toHaveBeenCalledWith("B", { objective: "B goal", tokenBudget: null });
});
