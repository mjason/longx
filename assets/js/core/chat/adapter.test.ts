import { describe, expect, test, vi } from "vitest";
import { buildAdapter, textOf } from "./adapter";
import { emptyView } from "./thread";

vi.mock("@/ash_rpc", () => ({
  sendMessage: vi.fn(async () => ({ success: true, data: { id: "turn-row" } })),
  interruptTurn: vi.fn(async () => ({ success: true, data: null })),
  respond: vi.fn(async () => ({ success: true, data: null })),
}));
import { interruptTurn, respond, sendMessage } from "@/ash_rpc";

const target = { threadId: "row-1", codexThreadId: "thr_1" };
const append = (text: string) => ({ role: "user", content: [{ type: "text", text }], parentId: null, sourceId: null, runConfig: undefined }) as never;

describe("chat adapter", () => {
  test("onNew sends the text (and the chosen model) as a turn", async () => {
    const adapter = buildAdapter({ target, view: emptyView("thr_1"), model: "glm-5" });
    await adapter.onNew(append("  hello  "));
    expect(sendMessage).toHaveBeenCalledWith(expect.objectContaining({ input: { threadId: "row-1", text: "hello", model: "glm-5" } }));
    expect(adapter.isRunning).toBe(false);
  });

  test("onCancel interrupts the turn in flight only", async () => {
    const idle = buildAdapter({ target, view: emptyView("thr_1"), model: null });
    await idle.onCancel!();
    expect(interruptTurn).not.toHaveBeenCalled();

    const running = buildAdapter({ target, view: { ...emptyView("thr_1"), turn: { id: "turn_9", status: "inProgress" } }, model: null });
    expect(running.isRunning).toBe(true);
    await running.onCancel!();
    expect(interruptTurn).toHaveBeenCalledWith(expect.objectContaining({ input: { threadId: "row-1", codexTurnId: "turn_9" } }));
  });

  test("an approval answer goes back as codex's request id and our decision", async () => {
    const view = { ...emptyView("thr_1"), requests: [{ id: 42, method: "item/commandExecution/requestApproval", params: { requestId: 42, itemId: "c1" } }] };
    const adapter = buildAdapter({ target, view, model: null });
    await adapter.onRespondToToolApproval!({ approvalId: "42", approved: true, optionId: "accept_for_session" });
    expect(respond).toHaveBeenCalledWith(expect.objectContaining({ input: { threadId: "row-1", requestId: "42", decision: "accept_for_session" } }));
    await adapter.onRespondToToolApproval!({ approvalId: "42", approved: false });
    expect(respond).toHaveBeenLastCalledWith(expect.objectContaining({ input: expect.objectContaining({ decision: "decline" }) }));
  });

  test("a dirty tree asks the page what to do, then resends with the answer", async () => {
    const dirty = {
      success: false,
      errors: [{ type: "dirty_tree", message: "dirty", shortMessage: "dirty", vars: {}, fields: [], path: [], details: { changes: [{ path: "a.txt", status: "modified" }] } }],
    };
    vi.mocked(sendMessage).mockResolvedValueOnce(dirty as never);
    const onDirtyTree = vi.fn(async () => "commit" as const);
    const adapter = buildAdapter({ target, view: emptyView("thr_1"), model: null, onDirtyTree });
    await adapter.onNew(append("go"));
    expect(onDirtyTree).toHaveBeenCalledWith([{ path: "a.txt", status: "modified" }]);
    expect(sendMessage).toHaveBeenLastCalledWith(expect.objectContaining({ input: { threadId: "row-1", text: "go", dirty: "commit" } }));

    // declining leaves the message unsent, without an error
    vi.mocked(sendMessage).mockResolvedValueOnce(dirty as never);
    const cancel = buildAdapter({ target, view: emptyView("thr_1"), model: null, onDirtyTree: async () => null });
    const before = vi.mocked(sendMessage).mock.calls.length;
    await expect(cancel.onNew(append("go"))).resolves.toBeUndefined();
    expect(vi.mocked(sendMessage).mock.calls.length).toBe(before + 1);
  });

  test("textOf joins text parts and trims", () => {
    expect(textOf(append(" a "))).toBe("a");
  });
});
