import { describe, expect, test } from "vitest";
import { activate, closeTab, EMPTY_WORKBENCH, markDirty, openTab, renamePath, tabKey, type WorkbenchState } from "./workbench";

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
