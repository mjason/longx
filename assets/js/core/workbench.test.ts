import { describe, expect, test } from "vitest";
import { activate, closeTab, EMPTY_WORKBENCH, markDirty, openTab, renamePath, tabKey, type WorkbenchState, stepTab, tabAt, createWorkbenchStore } from "./workbench";

describe("workbench tabs", () => {
  test("the chat is always the first tab; opening a file adds it once and activates it", () => {
    let s: WorkbenchState = EMPTY_WORKBENCH;
    s = openTab(s, { kind: "file", path: "lib/a.ex" });
    s = openTab(s, { kind: "file", path: "README.md" });
    s = openTab(s, { kind: "file", path: "lib/a.ex" });
    expect(s.tabs.map(tabKey)).toEqual(["chat", "file:lib/a.ex", "file:README.md"]);
    expect(s.active).toBe("file:lib/a.ex");
  });

  test("closing the active tab activates its neighbour; the chat cannot be closed", () => {
    let s = openTab(openTab(EMPTY_WORKBENCH, { kind: "file", path: "a" }), { kind: "file", path: "b" });
    s = closeTab(s, "file:b");
    expect(s.active).toBe("file:a");
    s = closeTab(s, "file:a");
    expect(s.active).toBe("chat");
    expect(closeTab(s, "chat").tabs).toHaveLength(1);
  });

  test("dirty marks survive activation; a rename moves the tab with the file", () => {
    let s = openTab(EMPTY_WORKBENCH, { kind: "file", path: "a" });
    s = markDirty(s, "file:a", true);
    s = activate(s, "chat");
    expect(s.dirty).toEqual(["file:a"]);
    s = renamePath(s, "a", "b");
    expect(s.tabs.map(tabKey)).toEqual(["chat", "file:b"]);
    expect(s.dirty).toEqual(["file:b"]);
    // a diff tab for the same path moves too
    s = openTab(s, { kind: "diff", path: "b", sha: null });
    s = renamePath(s, "b", "c");
    expect(s.tabs.map(tabKey)).toEqual(["chat", "file:c", "diff:c@"]);
  });
});

describe("artifact tabs", () => {
  test("an artifact is a tab kind of its own (a native client may open it in a window); keyed by id, closable, untouched by renames", () => {
    let s: WorkbenchState = openTab(EMPTY_WORKBENCH, { kind: "artifact", id: "i9", title: "报表", html: "<h1>x</h1>" });
    expect(s.tabs.map(tabKey)).toEqual(["chat", "artifact:i9"]);
    expect(s.active).toBe("artifact:i9");
    s = renamePath(s, "a", "b");
    expect(s.tabs[1]).toEqual({ kind: "artifact", id: "i9", title: "报表", html: "<h1>x</h1>" });
    expect(closeTab(s, "artifact:i9").tabs.map(tabKey)).toEqual(["chat"]);
  });

  test("artifacts are not remembered on the device: the html lives in the thread, the row reopens it", async () => {
    const { createWorkbenchStore } = await import("./workbench");
    const memory = new Map<string, string>();
    const storage = { getItem: (k: string) => memory.get(k) ?? null, setItem: (k: string, v: string) => void memory.set(k, v) };
    const store = createWorkbenchStore(storage, "wb");
    store.open({ kind: "file", path: "a.ex" });
    store.open({ kind: "artifact", id: "i9", title: "报表", html: "<h1>x</h1>" });
    expect(store.get().tabs).toHaveLength(3);
    const again = createWorkbenchStore(storage, "wb");
    expect(again.get().tabs.map(tabKey)).toEqual(["chat", "file:a.ex"]);
  });
});

describe("agent tabs", () => {
  test("a sub-agent's conversation is a tab kind of its own, keyed by its kernel thread, closable, remembered on the device", async () => {
    let s: WorkbenchState = openTab(EMPTY_WORKBENCH, { kind: "agent", threadId: "native_c1", rowId: "t9", name: "coder-2" });
    expect(s.tabs.map(tabKey)).toEqual(["chat", "agent:native_c1"]);
    expect(s.active).toBe("agent:native_c1");
    // opened again: the same tab, the details refreshed
    s = openTab(s, { kind: "agent", threadId: "native_c1", rowId: "t9", name: "coder-2" });
    expect(s.tabs).toHaveLength(2);
    expect(closeTab(s, "agent:native_c1").tabs.map(tabKey)).toEqual(["chat"]);

    const { createWorkbenchStore } = await import("./workbench");
    const memory = new Map<string, string>();
    const storage = { getItem: (k: string) => memory.get(k) ?? null, setItem: (k: string, v: string) => void memory.set(k, v) };
    const store = createWorkbenchStore(storage, "wb2");
    store.open({ kind: "agent", threadId: "native_c1", rowId: "t9", name: "coder-2" });
    expect(createWorkbenchStore(storage, "wb2").get().tabs.map(tabKey)).toEqual(["chat", "agent:native_c1"]);
  });
});

describe("conversation and project settings tabs", () => {
  test.each([
    { tabs: [{ kind: "chat", threadId: "t1" }, { kind: "chat", threadId: "t2" }], active: "chat:t2" },
    { tabs: [{ kind: "file", path: "README.md" }], active: "file:README.md" },
  ])("restoring existing tabs does not inject a new conversation: $active", (saved) => {
    const storage = { getItem: () => JSON.stringify(saved), setItem: () => {} };
    expect(createWorkbenchStore(storage, "wb").get()).toEqual({ ...saved, dirty: [] });
  });

  test("restoring an empty workspace opens a new conversation; a missing active key falls back to an existing tab", () => {
    const load = (saved: unknown) => createWorkbenchStore({ getItem: () => JSON.stringify(saved), setItem: () => {} }, "wb").get();
    expect(load({ tabs: [], active: "chat:t1" })).toEqual(EMPTY_WORKBENCH);
    expect(load({ tabs: [{ kind: "chat", threadId: "t1" }], active: "missing" }).active).toBe("chat:t1");
  });

  test("each conversation has a stable tab; refreshed titles replace the old details", () => {
    let s = openTab(EMPTY_WORKBENCH, { kind: "chat", threadId: "t1", title: "first" });
    s = openTab(s, { kind: "chat", threadId: "t2", title: "second" });
    s = openTab(s, { kind: "chat", threadId: "t1", title: "renamed" });
    expect(s.tabs.map(tabKey)).toEqual(["chat:t1", "chat:t2"]);
    expect(s.tabs[0]).toEqual({ kind: "chat", threadId: "t1", title: "renamed" });
    expect(closeTab(s, "chat:t1").tabs.map(tabKey)).toEqual(["chat:t2"]);
    expect(closeTab(openTab(EMPTY_WORKBENCH, { kind: "chat", threadId: "t1" }), "chat:t1").tabs.map(tabKey)).toEqual(["chat"]);
  });

  test("project settings can be activated and closed like another workspace tab", () => {
    let s = openTab(EMPTY_WORKBENCH, { kind: "settings" });
    expect(s.tabs.map(tabKey)).toEqual(["chat", "settings"]);
    expect(closeTab(s, "settings").tabs.map(tabKey)).toEqual(["chat"]);
  });
});

describe("moving between tabs (the space menu's SPC b / SPC TAB / SPC 1…9)", () => {
  test("next and previous wrap around; a number is the tab at that place", () => {
    let s = openTab(openTab(EMPTY_WORKBENCH, { kind: "file", path: "a.ex" }), { kind: "file", path: "b.ex" });
    expect(s.active).toBe("file:b.ex");
    expect(stepTab(s, 1).active).toBe("chat");
    expect(stepTab(s, -1).active).toBe("file:a.ex");
    expect(tabAt(s, 1)).toBe("chat");
    expect(tabAt(s, 2)).toBe("file:a.ex");
    expect(tabAt(s, 9)).toBeNull();
    s = activate(s, "chat");
    expect(stepTab(s, -1).active).toBe("file:b.ex");
  });

  test("the store remembers the tab before and the tabs closed: back goes to the one before, reopen brings the last closed", () => {
    const store = createWorkbenchStore(null, "t");
    store.open({ kind: "file", path: "a.ex" });
    store.open({ kind: "diff", path: "a.ex", sha: null });
    store.back();
    expect(store.get().active).toBe("file:a.ex");
    store.back();
    expect(store.get().active).toBe("diff:a.ex@");

    store.close("diff:a.ex@");
    store.close("file:a.ex");
    expect(store.get().tabs).toEqual([{ kind: "chat" }]);
    expect(store.canReopen()).toBe(true);
    store.reopen();
    expect(store.get().active).toBe("file:a.ex");
    store.reopen();
    expect(store.get().active).toBe("diff:a.ex@");
    expect(store.canReopen()).toBe(false);
  });

  test("Ctrl+Tab walks the tabs by last use while Ctrl is held; letting go settles there", () => {
    const store = createWorkbenchStore(null, "t");
    store.open({ kind: "file", path: "a.ex" });
    store.open({ kind: "file", path: "b.ex" });
    store.open({ kind: "file", path: "c.ex" });
    // last use: c, b, a, chat
    store.cycle(1);
    expect(store.get().active).toBe("file:b.ex");
    store.cycle(1);
    expect(store.get().active).toBe("file:a.ex");
    store.cycle(-1);
    expect(store.get().active).toBe("file:b.ex");
    store.endCycle();
    // b is the newest now: one Ctrl+Tab goes back to c
    store.cycle(1);
    expect(store.get().active).toBe("file:c.ex");
    store.endCycle();
    store.cycle(1);
    store.cycle(1);
    store.cycle(1);
    expect(store.get().active).toBe("chat");
    store.cycle(1);
    expect(store.get().active).toBe("file:c.ex");
  });
});
