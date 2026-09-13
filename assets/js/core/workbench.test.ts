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
