import { describe, expect, test, vi } from "vitest";
import { createRegistry } from "./registry";
import { formatSequence, lookup, visibleChildren, type KeyNode } from "./keymap";
import { CLOSED, ESC_WINDOW_MS, press, type KeyInput, type KeyTable } from "./engine";
import type { Binding } from "./bindings";

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
const bindings: Binding[] = [
  { keys: "mod+k", command: "palette.open", inLayer: true },
  { keys: "alt+ArrowDown", command: "thread.next", when: { editor: false } },
  { keys: "mod+w", command: "tab.close", when: { app: true } },
  { keys: "Escape Escape", command: "turn.stop" },
];
const table: KeyTable = { tree, bindings };

const CODES: Record<string, string> = { k: "KeyK", w: "KeyW", b: "KeyB", d: "KeyD", ArrowDown: "ArrowDown" };
const key = (k: string, extra: Partial<KeyInput> = {}): KeyInput => ({
  key: k,
  code: CODES[k] ?? "",
  ctrlKey: false,
  metaKey: false,
  altKey: false,
  shiftKey: false,
  composing: false,
  typing: false,
  editor: false,
  layerOpen: false,
  nativeSpace: false,
  app: false,
  mac: true,
  leader: true,
  now: 1_000,
  ...extra,
});

describe("the key tree", () => {
  test("a sequence finds its node and is shown", () => {
    expect(lookup(tree, ["b", "d"])).toMatchObject({ command: "tab.close" });
    expect(lookup(tree, ["b"])).toMatchObject({ label: "标签" });
    expect(lookup(tree, ["x"])).toBeNull();
    expect(formatSequence([" ", "b", "d"])).toBe("SPC b d");
    expect(formatSequence(["Tab"])).toBe("TAB");
    expect(formatSequence([" ", " "])).toBe("SPC SPC");
  });

  test("only what can run now is offered: a group without an available command is hidden", () => {
    const available = (id: string) => id !== "git.push" && id !== "tab.next";
    expect(visibleChildren(tree, [], available).map((n) => n.key)).toEqual([" ", ":", "b"]);
    expect(visibleChildren(tree, ["b"], available).map((n) => n.key)).toEqual(["d"]);
  });
});

describe("the space menu", () => {
  const all = () => true;

  test("space outside a text field opens it; the keys walk the tree and a command runs and closes it", () => {
    let r = press(CLOSED, key(" "), table, all);
    expect(r.action).toEqual({ type: "open" });
    expect(r.state).toMatchObject({ open: true, sequence: [] });

    r = press(r.state, key("b"), table, all);
    expect(r.action).toEqual({ type: "descend" });
    expect(r.state.sequence).toEqual(["b"]);

    r = press(r.state, key("d"), table, all);
    expect(r.action).toEqual({ type: "run", command: "tab.close" });
    expect(r.state).toEqual(CLOSED);
  });

  test("SPC SPC is the AI's input", () => {
    const opened = press(CLOSED, key(" "), table, all).state;
    expect(press(opened, key(" "), table, all).action).toEqual({ type: "run", command: "ai.focus" });
  });

  test("backspace goes up a level, escape closes, a key with nothing bound stays and says so", () => {
    let s = press(press(CLOSED, key(" "), table, all).state, key("b"), table, all).state;
    let r = press(s, key("Backspace"), table, all);
    expect(r).toMatchObject({ action: { type: "back" }, state: { open: true, sequence: [] } });
    r = press(r.state, key("Backspace"), table, all);
    expect(r).toMatchObject({ action: { type: "close" }, state: CLOSED });

    s = press(CLOSED, key(" "), table, all).state;
    r = press(s, key("z"), table, all);
    expect(r.action).toEqual({ type: "unknown" });
    expect(r.state).toMatchObject({ open: true, sequence: [] });
    // a command that cannot run now is no command
    r = press(press(s, key("g"), table, all).state, key("p"), table, (id) => id !== "git.push");
    expect(r.action.type).toBe("unknown");

    r = press(s, key("Escape"), table, all);
    expect(r).toMatchObject({ action: { type: "close" }, state: CLOSED });
  });

  test("a modifier alone is swallowed; a chord closes the menu and runs what it is bound to, else goes on to the browser", () => {
    const s = press(CLOSED, key(" "), table, all).state;
    expect(press(s, key("Shift", { shiftKey: true }), table, all)).toMatchObject({ action: { type: "consume" }, state: s });
    expect(press(s, key("k", { metaKey: true }), table, all)).toMatchObject({ action: { type: "run", command: "palette.open" }, state: CLOSED });
    expect(press(s, key("r", { metaKey: true, code: "KeyR" }), table, all)).toMatchObject({ action: { type: "close-pass" }, state: CLOSED });
  });

  test("typing: space is a space; escape leaves the field — unless an IME is composing or a popover is open", () => {
    const none = () => false;
    expect(press(CLOSED, key(" ", { typing: true }), table, all).action).toEqual({ type: "none" });
    expect(press(CLOSED, key("Escape", { typing: true }), table, none).action).toEqual({ type: "leave-input" });
    expect(press(CLOSED, key("Escape", { typing: true, composing: true }), table, all).action).toEqual({ type: "none" });
    expect(press(CLOSED, key("Process", { typing: true }), table, all).action).toEqual({ type: "none" });
    expect(press(CLOSED, key("Escape", { typing: true, layerOpen: true }), table, all).action).toEqual({ type: "none" });
  });

  test("space stays the browser's on a dialog, with a modifier, on a control reached by keyboard, or with the menu turned off", () => {
    expect(press(CLOSED, key(" ", { layerOpen: true }), table, all).action).toEqual({ type: "none" });
    expect(press(CLOSED, key(" ", { ctrlKey: true }), table, all).action).toEqual({ type: "none" });
    expect(press(CLOSED, key(" ", { nativeSpace: true }), table, all).action).toEqual({ type: "none" });
    expect(press(CLOSED, key(" ", { leader: false }), table, all).action).toEqual({ type: "none" });
  });
});

describe("chords", () => {
  const all = () => true;

  test("a chord runs its command wherever it holds; with nothing to run the key is the browser's", () => {
    expect(press(CLOSED, key("ArrowDown", { altKey: true, typing: true }), table, all).action).toEqual({ type: "run", command: "thread.next" });
    expect(press(CLOSED, key("ArrowDown", { altKey: true, typing: true, editor: true }), table, all).action).toEqual({ type: "none" });
    expect(press(CLOSED, key("k", { metaKey: true, layerOpen: true }), table, all).action).toEqual({ type: "run", command: "palette.open" });
    // ⌘W: a tab's own, the app's to close a tab
    expect(press(CLOSED, key("w", { metaKey: true }), table, all).action).toEqual({ type: "none" });
    expect(press(CLOSED, key("w", { metaKey: true, app: true }), table, all).action).toEqual({ type: "run", command: "tab.close" });
    // Ctrl off a Mac is mod
    expect(press(CLOSED, key("k", { ctrlKey: true, mac: false }), table, all).action).toEqual({ type: "run", command: "palette.open" });
  });
});

describe("Esc Esc", () => {
  const running = () => true;

  test("from the composer: the first Esc leaves it and arms the stop, the second within the window stops the turn", () => {
    let r = press(CLOSED, key("Escape", { typing: true, now: 1_000 }), table, running);
    expect(r.action).toEqual({ type: "leave-input" });
    expect(r.state.armed).toEqual({ command: "turn.stop", at: 1_000 });
    r = press(r.state, key("Escape", { now: 1_000 + ESC_WINDOW_MS - 1 }), table, running);
    expect(r.action).toEqual({ type: "run", command: "turn.stop" });
    expect(r.state.armed).toBeNull();
  });

  test("outside a text field the first Esc arms (and goes on as usual); too late, it only arms again", () => {
    let r = press(CLOSED, key("Escape", { now: 1_000 }), table, running);
    expect(r.action).toEqual({ type: "arm", command: "turn.stop" });
    r = press(r.state, key("Escape", { now: 1_000 + ESC_WINDOW_MS + 1 }), table, running);
    expect(r.action).toEqual({ type: "arm", command: "turn.stop" });
  });

  test("nothing running: Esc is just Esc; another key between the two disarms; a dialog's Esc is the dialog's", () => {
    expect(press(CLOSED, key("Escape"), table, () => false).action).toEqual({ type: "none" });

    let r = press(CLOSED, key("Escape"), table, running);
    r = press(r.state, key("x"), table, running);
    expect(r.state.armed).toBeNull();
    expect(press(r.state, key("Escape", { now: 1_100 }), table, running).action).toEqual({ type: "arm", command: "turn.stop" });

    r = press(CLOSED, key("Escape"), table, running);
    const layer = press(r.state, key("Escape", { layerOpen: true, now: 1_100 }), table, running);
    expect(layer.action).toEqual({ type: "none" });
    expect(layer.state.armed).toBeNull();
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
