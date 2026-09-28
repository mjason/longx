import { describe, expect, test, vi } from "vitest";
import { createRegistry } from "./registry";
import { formatSequence, lookup, sequenceOf, SPACE_TREE, visibleChildren, type KeyNode } from "./keymap";
import { CLOSED, press, type KeyInput } from "./engine";

const tree: KeyNode[] = [
  { key: " ", label: "和 AI 对话", command: "ai.focus" },
  { key: ":", label: "命令面板", command: "palette.open" },
  {
    key: "b",
    label: "标签",
    children: [
      { key: "d", label: "关闭标签", command: "tab.close" },
      { key: "n", label: "下一个标签", command: "tab.next" },
    ],
  },
  { key: "g", label: "Git", children: [{ key: "p", label: "推送", command: "git.push" }] },
];

const key = (k: string, extra: Partial<KeyInput> = {}): KeyInput => ({
  key: k,
  ctrl: false,
  meta: false,
  alt: false,
  composing: false,
  typing: false,
  layerOpen: false,
  nativeSpace: false,
  ...extra,
});

describe("the key tree", () => {
  test("a sequence finds its node; a command's sequence is found back and shown", () => {
    expect(lookup(tree, ["b", "d"])).toMatchObject({ command: "tab.close" });
    expect(lookup(tree, ["b"])).toMatchObject({ label: "标签" });
    expect(lookup(tree, ["x"])).toBeNull();
    expect(sequenceOf(tree, "tab.close")).toEqual(["b", "d"]);
    expect(sequenceOf(tree, "nope")).toBeNull();
    expect(formatSequence([" ", "b", "d"])).toBe("SPC b d");
    expect(formatSequence(["Tab"])).toBe("TAB");
    expect(formatSequence([" ", " "])).toBe("SPC SPC");
  });

  test("only what can run now is offered: a group without an available command is hidden", () => {
    const available = (id: string) => id !== "git.push" && id !== "tab.next";
    expect(visibleChildren(tree, [], available).map((n) => n.key)).toEqual([" ", ":", "b"]);
    expect(visibleChildren(tree, ["b"], available).map((n) => n.key)).toEqual(["d"]);
  });

  test("the shipped tree: every command has one sequence, and the ones the page names are there", () => {
    const ids: string[] = [];
    const walk = (nodes: KeyNode[]) => nodes.forEach((n) => (n.command ? ids.push(n.command) : walk(n.children ?? [])));
    walk(SPACE_TREE);
    expect(new Set(ids).size).toBe(ids.length);
    for (const id of ["ai.focus", "palette.open", "help.keys", "turn.stop", "tab.close", "tab.reopen", "file.find", "git.push", "project.switch"]) {
      expect(ids).toContain(id);
    }
    expect(formatSequence([" ", ...sequenceOf(SPACE_TREE, "turn.stop")!])).toBe("SPC a s");
  });
});

describe("the space menu", () => {
  const all = () => true;

  test("space outside a text field opens it; the keys walk the tree and a command runs and closes it", () => {
    let s = CLOSED;
    let r = press(s, key(" "), tree, all);
    expect(r.action).toEqual({ type: "open" });
    s = r.state;
    expect(s).toMatchObject({ open: true, sequence: [] });

    r = press(s, key("b"), tree, all);
    expect(r.action).toEqual({ type: "descend" });
    expect(r.state.sequence).toEqual(["b"]);

    r = press(r.state, key("d"), tree, all);
    expect(r.action).toEqual({ type: "run", command: "tab.close" });
    expect(r.state).toEqual(CLOSED);
  });

  test("SPC SPC is the AI's input", () => {
    const opened = press(CLOSED, key(" "), tree, all).state;
    expect(press(opened, key(" "), tree, all).action).toEqual({ type: "run", command: "ai.focus" });
  });

  test("backspace goes up a level, escape closes, a key with nothing bound stays and says so", () => {
    let s = press(press(CLOSED, key(" "), tree, all).state, key("b"), tree, all).state;
    let r = press(s, key("Backspace"), tree, all);
    expect(r).toMatchObject({ action: { type: "back" }, state: { open: true, sequence: [] } });
    r = press(r.state, key("Backspace"), tree, all);
    expect(r).toMatchObject({ action: { type: "close" }, state: CLOSED });

    s = press(CLOSED, key(" "), tree, all).state;
    r = press(s, key("z"), tree, all);
    expect(r.action).toEqual({ type: "unknown" });
    expect(r.state).toMatchObject({ open: true, sequence: [] });
    // a command that cannot run now is no command
    r = press(press(s, key("g"), tree, all).state, key("p"), tree, (id) => id !== "git.push");
    expect(r.action.type).toBe("unknown");

    r = press(s, key("Escape"), tree, all);
    expect(r).toMatchObject({ action: { type: "close" }, state: CLOSED });
  });

  test("shift, ctrl and the like alone are swallowed; a chord with ctrl or meta leaves the menu to the browser", () => {
    const s = press(CLOSED, key(" "), tree, all).state;
    expect(press(s, key("Shift"), tree, all)).toMatchObject({ action: { type: "consume" }, state: s });
    const r = press(s, key("k", { meta: true }), tree, all);
    expect(r).toMatchObject({ action: { type: "close-pass" }, state: CLOSED });
  });

  test("typing: space is a space; escape leaves the field — unless an IME is composing or a popover is open", () => {
    expect(press(CLOSED, key(" ", { typing: true }), tree, all).action).toEqual({ type: "none" });
    expect(press(CLOSED, key("Escape", { typing: true }), tree, all).action).toEqual({ type: "leave-input" });
    expect(press(CLOSED, key("Escape", { typing: true, composing: true }), tree, all).action).toEqual({ type: "none" });
    expect(press(CLOSED, key("Process", { typing: true }), tree, all).action).toEqual({ type: "none" });
    expect(press(CLOSED, key("Escape", { typing: true, layerOpen: true }), tree, all).action).toEqual({ type: "none" });
  });

  test("space stays the browser's on a dialog, with a modifier, or on a control reached by keyboard", () => {
    expect(press(CLOSED, key(" ", { layerOpen: true }), tree, all).action).toEqual({ type: "none" });
    expect(press(CLOSED, key(" ", { ctrl: true }), tree, all).action).toEqual({ type: "none" });
    expect(press(CLOSED, key(" ", { nativeSpace: true }), tree, all).action).toEqual({ type: "none" });
  });
});

describe("the command registry", () => {
  test("the last registration of an id wins until it goes; availability follows its predicate", () => {
    const registry = createRegistry();
    const first = vi.fn();
    const second = vi.fn();
    const offFirst = registry.register({ id: "tab.close", run: first });
    const offSecond = registry.register({ id: "tab.close", run: second, available: () => true });
    expect(registry.available("tab.close")).toBe(true);
    registry.run("tab.close");
    expect(second).toHaveBeenCalledOnce();
    offSecond();
    registry.run("tab.close");
    expect(first).toHaveBeenCalledOnce();
    offFirst();
    expect(registry.available("tab.close")).toBe(false);

    registry.register({ id: "turn.stop", run: vi.fn(), available: () => false });
    expect(registry.available("turn.stop")).toBe(false);
    expect(registry.run("turn.stop")).toBe(false);
  });

  test("listeners hear about registrations", () => {
    const registry = createRegistry();
    const heard = vi.fn();
    registry.subscribe(heard);
    const off = registry.register({ id: "x", run: vi.fn() });
    off();
    expect(heard).toHaveBeenCalledTimes(2);
  });
});
