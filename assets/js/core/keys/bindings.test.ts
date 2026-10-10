import { describe, expect, test } from "vitest";
import { COMMANDS, GROUPS, commandTitle } from "./commands";
import { canonical, eventChord, formatKeys, parseLeader } from "./notation";
import {
  chordCommand,
  DEFAULT_BINDINGS,
  escapeCommand,
  imeKey,
  keysFor,
  leaderTree,
  reservedInTab,
  type Binding,
  type KeyContext,
} from "./bindings";
import { effectiveBindings, validateKeys } from "./overrides";
import { lookup } from "./keymap";

const ev = (key: string, code: string, mods: { meta?: boolean; ctrl?: boolean; alt?: boolean; shift?: boolean } = {}) => ({
  key,
  code,
  metaKey: mods.meta ?? false,
  ctrlKey: mods.ctrl ?? false,
  altKey: mods.alt ?? false,
  shiftKey: mods.shift ?? false,
});

const ctx = (over: Partial<KeyContext> = {}): KeyContext => ({ typing: false, editor: false, layer: false, app: false, mac: true, ...over });
const all = () => true;

describe("key notation", () => {
  test("an event becomes the key it means: ⌘ on a Mac and Ctrl elsewhere are both `mod`; letters by their key cap", () => {
    expect(eventChord(ev("k", "KeyK", { meta: true }), true)).toBe("mod+k");
    expect(eventChord(ev("k", "KeyK", { ctrl: true }), false)).toBe("mod+k");
    // ⌥A types å on a Mac: the chord is still alt+a
    expect(eventChord(ev("å", "KeyA", { alt: true }), true)).toBe("alt+a");
    expect(eventChord(ev("ArrowDown", "ArrowDown", { alt: true, shift: true }), true)).toBe("alt+shift+ArrowDown");
    expect(eventChord(ev("Tab", "Tab", { ctrl: true }), true)).toBe("ctrl+Tab");
    expect(eventChord(ev("Tab", "Tab", { ctrl: true }), false)).toBe("mod+Tab");
    expect(eventChord(ev("T", "KeyT", { meta: true, shift: true }), true)).toBe("mod+shift+t");
    // a bare key is the character it types (the space menu's keys)
    expect(eventChord(ev("T", "KeyT", { shift: true }), true)).toBe("T");
    expect(eventChord(ev("?", "Slash", { shift: true }), true)).toBe("?");
    expect(eventChord(ev("Escape", "Escape"), true)).toBe("Escape");
    // a modifier alone is no key
    expect(eventChord(ev("Meta", "MetaLeft", { meta: true }), true)).toBeNull();
  });

  test("a binding's keys in one spelling: ctrl is mod off a Mac, modifiers in order, letters small", () => {
    expect(canonical("ctrl+Tab", false)).toBe("mod+Tab");
    expect(canonical("ctrl+Tab", true)).toBe("ctrl+Tab");
    expect(canonical("shift+mod+T", true)).toBe("mod+shift+t");
    expect(canonical("SPC a s", true)).toBe("SPC a s");
  });

  test("shown the platform's way", () => {
    expect(formatKeys("mod+shift+t", true)).toBe("⌘⇧T");
    expect(formatKeys("mod+shift+t", false)).toBe("Ctrl+Shift+T");
    expect(formatKeys("alt+ArrowDown", true)).toBe("⌥↓");
    expect(formatKeys("alt+ArrowDown", false)).toBe("Alt+↓");
    expect(formatKeys("ctrl+PageDown", false)).toBe("Ctrl+PgDn");
    expect(formatKeys("Escape Escape", true)).toBe("Esc Esc");
    expect(formatKeys("SPC a s", true)).toBe("SPC a s");
    expect(formatKeys("SPC TAB", false)).toBe("SPC TAB");
    expect(parseLeader("SPC SPC")).toEqual([" "]);
    expect(parseLeader("SPC TAB")).toEqual(["Tab"]);
    expect(parseLeader("SPC a s")).toEqual(["a", "s"]);
    expect(parseLeader("mod+k")).toBeNull();
  });
});

describe("the shipped key table", () => {
  test("every command is in the catalog with a name; every leader group has one", () => {
    for (const b of DEFAULT_BINDINGS) {
      expect(COMMANDS[b.command], b.command).toBeTruthy();
      const seq = parseLeader(b.keys);
      if (seq && seq.length === 2) expect(GROUPS[seq[0]!], b.keys).toBeTruthy();
    }
    expect(commandTitle("tab.goto.3")).toBe("第 3 个标签");
  });

  test("no key a browser tab keeps for itself unless the binding is the installed app's", () => {
    for (const mac of [true, false]) {
      for (const b of DEFAULT_BINDINGS) {
        if (reservedInTab(b.keys, mac)) expect(b.when?.app, `${b.keys} on ${mac ? "mac" : "pc"}`).toBe(true);
      }
    }
  });

  test("no key an input method uses: Ctrl+Space, Ctrl+., Shift+Space, ⌘Space", () => {
    for (const mac of [true, false]) for (const b of DEFAULT_BINDINGS) expect(imeKey(b.keys, mac), b.keys).toBe(false);
  });

  test("no two commands on one key where both could fire", () => {
    for (const mac of [true, false]) {
      const seen = new Map<string, Binding[]>();
      for (const b of DEFAULT_BINDINGS) {
        if (b.when?.mac !== undefined && b.when.mac !== mac) continue;
        const k = canonical(b.keys, mac);
        seen.set(k, [...(seen.get(k) ?? []), b]);
      }
      for (const [k, bs] of seen) {
        const commands = new Set(bs.map((b) => b.command));
        if (commands.size > 1) {
          // allowed only when the scenes exclude each other (the app and a tab)
          const apps = bs.map((b) => b.when?.app);
          expect(new Set(apps).size, `${k}: ${[...commands].join(", ")}`).toBe(bs.length);
        }
      }
    }
  });

  test("the space menu is built from the table: groups with their names, the keys under them", () => {
    const tree = leaderTree(DEFAULT_BINDINGS);
    expect(tree.map((n) => n.key).slice(0, 5)).toEqual([" ", ":", "?", "Tab", ","]);
    expect(lookup(tree, ["a"])).toMatchObject({ label: "对话" });
    expect(lookup(tree, ["a", "s"])).toMatchObject({ command: "turn.stop", label: "停止这一轮" });
    expect(lookup(tree, ["t", "n"])).toMatchObject({ command: "thread.next" });
    expect(lookup(tree, ["3"])).toMatchObject({ command: "tab.goto.3" });
    // what runs now has the lowercase key; renaming, rarer, the capital
    expect(lookup(tree, ["t", "r"])).toMatchObject({ command: "thread.running", label: "正在跑、刚完成的会话" });
    expect(lookup(tree, ["t", "R"])).toMatchObject({ command: "thread.rename" });
  });
});

describe("which command a key runs", () => {
  test("switching conversations with ⌥↑↓ works in the composer, not in the code editor, not over a dialog", () => {
    expect(chordCommand(DEFAULT_BINDINGS, "alt+ArrowDown", ctx({ typing: true }), all)).toBe("thread.next");
    expect(chordCommand(DEFAULT_BINDINGS, "alt+ArrowUp", ctx(), all)).toBe("thread.prev");
    expect(chordCommand(DEFAULT_BINDINGS, "alt+shift+ArrowDown", ctx(), all)).toBe("thread.waiting");
    expect(chordCommand(DEFAULT_BINDINGS, "alt+shift+ArrowUp", ctx({ typing: true }), all)).toBe("thread.running");
    expect(chordCommand(DEFAULT_BINDINGS, "alt+shift+ArrowUp", ctx({ typing: true, editor: true }), all)).toBeNull();
    expect(chordCommand(DEFAULT_BINDINGS, "alt+ArrowDown", ctx({ typing: true, editor: true }), all)).toBeNull();
    expect(chordCommand(DEFAULT_BINDINGS, "alt+ArrowDown", ctx({ layer: true }), all)).toBeNull();
  });

  test("⌘W is the installed app's; in a tab it stays the browser's, and with nothing to close it goes on to close the window", () => {
    expect(chordCommand(DEFAULT_BINDINGS, "mod+w", ctx(), all)).toBeNull();
    expect(chordCommand(DEFAULT_BINDINGS, "mod+w", ctx({ app: true }), all)).toBe("tab.close");
    expect(chordCommand(DEFAULT_BINDINGS, "mod+w", ctx({ app: true }), (id) => id !== "tab.close")).toBeNull();
    expect(chordCommand(DEFAULT_BINDINGS, "mod+shift+t", ctx({ app: true }), all)).toBe("tab.reopen");
    expect(chordCommand(DEFAULT_BINDINGS, "mod+t", ctx({ app: true }), all)).toBe("thread.new");
    expect(chordCommand(DEFAULT_BINDINGS, "ctrl+Tab", ctx({ app: true }), all)).toBe("tab.recent");
    expect(chordCommand(DEFAULT_BINDINGS, "mod+alt+ArrowRight", ctx({ app: true }), all)).toBe("tab.next");
    expect(chordCommand(DEFAULT_BINDINGS, "mod+PageDown", ctx({ app: true, mac: false }), all)).toBe("tab.next");
  });

  test("Control+Alt+W closes workspace tabs in a browser on both platforms, including from text fields", () => {
    expect(chordCommand(DEFAULT_BINDINGS, "ctrl+alt+w", ctx({ mac: true, typing: true }), all)).toBe("tab.close");
    expect(chordCommand(DEFAULT_BINDINGS, "mod+alt+w", ctx({ mac: false, typing: true }), all)).toBe("tab.close");
    expect(chordCommand(DEFAULT_BINDINGS, "ctrl+alt+w", ctx({ mac: true }), (id) => id !== "tab.close")).toBeNull();
  });

  test("⌘K toggles the palette even while it is open; ⌘S saves only what there is to save", () => {
    expect(chordCommand(DEFAULT_BINDINGS, "mod+k", ctx({ layer: true }), all)).toBe("palette.open");
    expect(chordCommand(DEFAULT_BINDINGS, "mod+s", ctx({ typing: true, editor: true }), all)).toBe("file.save");
    expect(chordCommand(DEFAULT_BINDINGS, "mod+s", ctx(), (id) => id !== "file.save")).toBeNull();
    expect(chordCommand(DEFAULT_BINDINGS, "mod+4", ctx({ typing: true }), all)).toBe("tool.files");
  });

  test("Esc Esc stops the turn while one runs", () => {
    expect(escapeCommand(DEFAULT_BINDINGS, ctx(), all)).toBe("turn.stop");
    expect(escapeCommand(DEFAULT_BINDINGS, ctx(), (id) => id !== "turn.stop")).toBeNull();
  });

  test("what a control's tooltip names: the key this window has, the space menu's when it is on", () => {
    expect(keysFor("tab.close", DEFAULT_BINDINGS, ctx(), true)).toEqual(["⌃⌥W", "SPC b d"]);
    expect(keysFor("tab.close", DEFAULT_BINDINGS, ctx({ app: true }), true)).toEqual(["⌘W", "⌃⌥W", "SPC b d"]);
    expect(keysFor("tab.close", DEFAULT_BINDINGS, ctx({ app: true, mac: false }), false)).toEqual(["Ctrl+W", "Ctrl+Alt+W"]);
    expect(keysFor("turn.stop", DEFAULT_BINDINGS, ctx(), true)).toEqual(["Esc Esc", "SPC a s"]);
    expect(keysFor("tab.next", DEFAULT_BINDINGS, ctx({ app: true, mac: false }), true)).toEqual(["Ctrl+PgDn", "SPC b n"]);
  });
});

describe("the person's own keys", () => {
  test("an override replaces a command's keys; a key a tab keeps becomes the app's", () => {
    const table = effectiveBindings(DEFAULT_BINDINGS, { "turn.stop": ["mod+shift+x", "SPC a x"], "tab.reopen": ["mod+shift+t"] }, true);
    expect(table.filter((b) => b.command === "turn.stop").map((b) => b.keys)).toEqual(["mod+shift+x", "SPC a x"]);
    expect(table.find((b) => b.command === "tab.reopen")).toMatchObject({ keys: "mod+shift+t", when: { app: true } });
    expect(chordCommand(table, "mod+shift+x", ctx(), all)).toBe("turn.stop");
  });

  test("a recorded key is refused when an input method uses it or another command has it", () => {
    expect(validateKeys("ctrl+ ", "turn.stop", DEFAULT_BINDINGS, false)).toMatchObject({ ok: false });
    const taken = validateKeys("mod+k", "turn.stop", DEFAULT_BINDINGS, true);
    expect(taken).toMatchObject({ ok: false });
    expect(taken.ok ? "" : taken.reason).toContain("命令面板");
    expect(validateKeys("SPC a s", "turn.continue", DEFAULT_BINDINGS, true)).toMatchObject({ ok: false });
    expect(validateKeys("mod+shift+x", "turn.stop", DEFAULT_BINDINGS, true)).toEqual({ ok: true, appOnly: false });
    // ⌘N is left to the system in the app; bound by the person, it is the app's only
    expect(validateKeys("mod+n", "turn.stop", DEFAULT_BINDINGS, true)).toEqual({ ok: true, appOnly: true });
    expect(validateKeys("mod+w", "turn.stop", DEFAULT_BINDINGS, true)).toMatchObject({ ok: false });
  });
});
