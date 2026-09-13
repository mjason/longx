import { describe, expect, test, vi } from "vitest";
import { buildThreadListAdapter } from "./threadList";

const rows = [
  { id: "t1", codexThreadId: "thr_1", title: "Fix tests", preview: null, status: "idle" },
  { id: "t2", codexThreadId: "thr_2", title: null, preview: "run ls and…", status: "active" },
  { id: "t3", codexThreadId: "thr_3", title: null, preview: null, status: "archived" },
];

describe("thread list adapter", () => {
  test("maps rows to assistant-ui thread data: title, then preview; archived apart", () => {
    const adapter = buildThreadListAdapter({ rows, currentId: "t2", actions: {} });
    expect(adapter.threadId).toBe("t2");
    expect(adapter.threads).toEqual([
      { status: "regular", id: "t1", title: "Fix tests" },
      { status: "regular", id: "t2", title: "run ls and…" },
    ]);
    expect(adapter.archivedThreads).toEqual([{ status: "archived", id: "t3", title: undefined }]);
  });

  test("handlers are wired only when given (assistant-ui hides the rest)", async () => {
    const actions = { switchTo: vi.fn(), create: vi.fn(async () => {}), rename: vi.fn(async () => {}), archive: vi.fn(async () => {}), delete: vi.fn(async () => {}) };
    const adapter = buildThreadListAdapter({ rows, currentId: undefined, actions });
    await adapter.onSwitchToThread!("t1");
    expect(actions.switchTo).toHaveBeenCalledWith("t1");
    await adapter.onSwitchToNewThread!();
    expect(actions.create).toHaveBeenCalled();
    await adapter.onRename!("t1", "New name");
    expect(actions.rename).toHaveBeenCalledWith("t1", "New name");
    await adapter.onArchive!("t1");
    expect(actions.archive).toHaveBeenCalledWith("t1");
    await adapter.onDelete!("t1");
    expect(actions.delete).toHaveBeenCalledWith("t1");
    expect(adapter.onUnarchive).toBeUndefined();

    const bare = buildThreadListAdapter({ rows, currentId: undefined, actions: {} });
    expect(bare.onRename).toBeUndefined();
  });
});
