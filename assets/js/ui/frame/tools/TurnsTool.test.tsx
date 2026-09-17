import { act, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, test, vi } from "vitest";
import { renderAt, setViewport } from "@/ui/test-utils";
import { _resetFrameStoreForTests } from "@/core/frame";
import { channel, ok } from "@/ui/test-mocks";

vi.mock("@/ash_rpc", async () => (await import("@/ui/test-mocks")).rpcMock());
vi.mock("@/core/socket", async () => (await import("@/ui/test-mocks")).socketMock());
import { listTurns, restoreFiles, restoreProposal } from "@/ash_rpc";

const turns = [
  { id: "tu1", kernelTurnId: "turn_1", userText: "add a test", modelSlug: "deepseek-flash", status: "completed", startedAt: "2026-09-13T01:00:00Z", completedAt: "2026-09-13T01:00:09Z", commitBefore: "aaaa1111bbbb", commitAfter: "cccc2222dddd", dirtyStart: false, diff: "diff --git a/lib/a.ex b/lib/a.ex\n--- a/lib/a.ex\n+++ b/lib/a.ex\n@@ -1 +1 @@\n-old\n+new\n", error: null },
  { id: "tu2", kernelTurnId: "turn_2", userText: "and docs", modelSlug: "deepseek-flash", status: "failed", startedAt: "2026-09-13T01:05:00Z", completedAt: "2026-09-13T01:05:03Z", commitBefore: "cccc2222dddd", commitAfter: null, dirtyStart: false, diff: null, error: "Longx restarted while this turn was running" },
];

async function openTool() {
  const user = userEvent.setup();
  const r = renderAt("/p/app-1/t/t1");
  await waitFor(() => expect(channel.topics).toContain("thread:thr_1"));
  await user.keyboard("{Meta>}3{/Meta}");
  const panel = await screen.findByTestId("tool-panel");
  await within(panel).findByText("add a test");
  return { user, panel, ...r };
}

describe("TurnsTool (history)", () => {
  beforeEach(() => {
    localStorage.clear();
    _resetFrameStoreForTests();
    channel.reset();
    setViewport(1280);
    vi.mocked(listTurns).mockResolvedValue(ok(turns) as never);
  });

  test("lists the thread's turns with status, model and commits; the diff opens per file", async () => {
    const { user, panel } = await openTool();
    expect(within(panel).getByText("and docs")).toBeInTheDocument();
    expect(within(panel).getByText(/Longx restarted/)).toBeInTheDocument();
    expect(within(panel).getByText("aaaa111")).toBeInTheDocument();
    await user.click(within(panel).getByRole("button", { name: /改动/ }));
    expect(await within(panel).findByText("lib/a.ex")).toBeInTheDocument();
    expect(within(panel).getByText("new")).toBeInTheDocument();
  });

  test("restore: the checkpoints are the turns' starting points; the proposal is shown, nothing happens without confirming", async () => {
    const { user, panel } = await openTool();
    vi.mocked(restoreProposal).mockResolvedValue(ok({ commit: "aaaa1111bbbb", dirtyNow: true, changedFiles: ["lib/a.ex", "README.md"], laterTurns: 1 }) as never);
    const checkpoints = within(panel).getByTestId("checkpoints");
    expect(checkpoints).toHaveTextContent("现在");
    expect(checkpoints).toHaveTextContent("1 个文件");
    // both turns started from a commit, so both are points to fall back to; "now" is not
    expect(within(checkpoints).getAllByRole("button", { name: /回到/ })).toHaveLength(2);
    await user.click(within(checkpoints).getByRole("button", { name: /回到 #1 add a test 之前/ }));
    const dialog = await screen.findByRole("dialog");
    expect(dialog).toHaveTextContent("README.md");
    expect(dialog).toHaveTextContent("1 轮");
    expect(restoreFiles).not.toHaveBeenCalled();
    await user.click(within(dialog).getByRole("button", { name: "恢复文件" }));
    await waitFor(() => expect(restoreFiles).toHaveBeenCalledWith(expect.objectContaining({ input: expect.objectContaining({ turnId: "tu1", confirm: true }) })));
    // no redo: a turn is run again by sending the message again
    expect(within(panel).queryByRole("button", { name: /重跑/ })).not.toBeInTheDocument();
  });
});
