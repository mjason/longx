// The one key table: every key the page answers to is a binding here — a
// chord (⌘K), a space-menu sequence (SPC a s) or Esc pressed twice — naming
// a command of the catalog (./commands) and the scene it holds in. The
// dispatcher (ui/keys/KeysLayer), the which-key panel, SPC ?, the palette,
// a button's tooltip and Settings → 快捷键 all read it; the person's own
// keys replace a command's here (./overrides). Plain data: a native client
// maps its menus to the same command ids.
//
// Scenes: `typing` (focus in a text field), `editor` (the code editor or a
// select, whose Alt+arrows are their own), `layer` (a dialog, menu or
// popover is open: a chord is skipped unless the binding says `inLayer`),
// `app` (the installed app's window — Chromium reserves no key there, so ⌘W
// and Ctrl+Tab reach the page; a browser tab keeps them), `mac`.
// A space-menu sequence holds only outside a text field and a layer.
import { COMMANDS, GROUPS } from "./commands";
import type { KeyNode } from "./keymap";
import { canonical, formatKeys, parseLeader } from "./notation";

export type KeyContext = { typing: boolean; editor: boolean; layer: boolean; app: boolean; mac: boolean };
export type When = Partial<Omit<KeyContext, "layer">>;
export type Binding = { keys: string; command: string; when?: When; inLayer?: boolean };

const spc = (seq: string, command: string): Binding => ({ keys: `SPC ${seq}`, command });
const app = (keys: string, command: string, extra: When = {}): Binding => ({ keys, command, when: { app: true, ...extra } });

export const ESC_ESC = "Escape Escape";

export const DEFAULT_BINDINGS: Binding[] = [
  spc("SPC", "ai.focus"),
  spc(":", "palette.open"),
  { keys: "mod+k", command: "palette.open", inLayer: true },
  spc("?", "help.keys"),
  spc("TAB", "tab.last"),
  spc(",", "settings.open"),
  ...Array.from({ length: 9 }, (_, i) => spc(String(i + 1), `tab.goto.${i + 1}`)),

  // SPC a — the conversation
  spc("a s", "turn.stop"),
  { keys: ESC_ESC, command: "turn.stop" },
  spc("a r", "turn.continue"),
  spc("a d", "turn.discard"),
  spc("a n", "thread.new"),
  app("mod+t", "thread.new"),
  spc("a c", "thread.compact"),
  spc("a g", "goal.open"),
  spc("a m", "model.pick"),
  spc("a e", "effort.pick"),
  spc("a w", "waiting.release"),
  spc("a y", "ask.open"),

  // SPC t — conversations (⌥↑↓ in the composer too; the code editor moves lines with them)
  spc("t t", "thread.switch"),
  spc("t l", "thread.last"),
  spc("t n", "thread.next"),
  { keys: "alt+ArrowDown", command: "thread.next", when: { editor: false } },
  spc("t p", "thread.prev"),
  { keys: "alt+ArrowUp", command: "thread.prev", when: { editor: false } },
  spc("t w", "thread.waiting"),
  { keys: "alt+shift+ArrowDown", command: "thread.waiting", when: { editor: false } },
  // what runs now, any project: a picker (⌥⇧↑ beside ⌥⇧↓); renaming, rarer, moved to the capital
  spc("t r", "thread.running"),
  { keys: "alt+shift+ArrowUp", command: "thread.running", when: { editor: false } },
  spc("t R", "thread.rename"),
  spc("t a", "thread.archive"),
  spc("t s", "subagents.open"),

  // SPC b — the tabs; the app window has the browser's own keys for them
  spc("b b", "tab.switch"),
  spc("b d", "tab.close"),
  app("mod+w", "tab.close"),
  { keys: "ctrl+alt+w", command: "tab.close" },
  spc("b u", "tab.reopen"),
  app("mod+shift+t", "tab.reopen"),
  spc("b n", "tab.next"),
  app("mod+alt+ArrowRight", "tab.next", { mac: true }),
  app("ctrl+PageDown", "tab.next", { mac: false }),
  spc("b p", "tab.prev"),
  app("mod+alt+ArrowLeft", "tab.prev", { mac: true }),
  app("ctrl+PageUp", "tab.prev", { mac: false }),
  app("ctrl+Tab", "tab.recent"),
  app("ctrl+shift+Tab", "tab.recentBack"),
  spc("b c", "tab.chat"),

  // SPC f — files
  spc("f f", "file.find"),
  spc("f t", "files.open"),
  spc("f s", "file.save"),
  { keys: "mod+s", command: "file.save" },
  spc("f l", "file.reveal"),

  // SPC g — Git
  spc("g g", "git.open"),
  spc("g c", "git.commit"),
  spc("g p", "git.push"),
  spc("g f", "git.pull"),
  spc("g l", "git.history"),
  spc("g b", "git.branches"),

  // SPC w — tool windows (⌘1–4, IDEA's habit)
  spc("w 1", "tool.threads"),
  { keys: "mod+1", command: "tool.threads" },
  spc("w 2", "tool.git"),
  { keys: "mod+2", command: "tool.git" },
  spc("w 3", "tool.agents"),
  { keys: "mod+3", command: "tool.agents" },
  spc("w 4", "tool.files"),
  { keys: "mod+4", command: "tool.files" },
  spc("w w", "tool.toggle"),
  spc("w a", "agents.panel"),

  // SPC p — the project
  spc("p p", "project.switch"),
  spc("p s", "project.settings"),
  spc("p n", "project.new"),

  // SPC j — jumps in the conversation
  spc("j j", "jump.bottom"),
  spc("j a", "jump.ask"),
  spc("j e", "jump.error"),

  // SPC T — toggles
  spc("T t", "toggle.theme"),
  spc("T r", "toggle.reasoning"),

  // SPC m — the tab on screen
  spc("m s", "file.save"),
  spc("m v", "editor.preview"),
  spc("m n", "diff.next"),
  spc("m p", "diff.prev"),
];

// the keys a Chromium tab keeps for itself (browser_command_controller.cc,
// IsReservedCommandOrKey — "In Apps mode, no keys are reserved")
const RESERVED_MAC = ["mod+w", "mod+shift+w", "mod+t", "mod+shift+t", "mod+n", "mod+shift+n", "mod+q", "ctrl+Tab", "ctrl+shift+Tab", "mod+alt+ArrowLeft", "mod+alt+ArrowRight", "mod+shift+{", "mod+shift+}"];
const RESERVED_PC = ["mod+w", "mod+F4", "mod+shift+w", "mod+t", "mod+shift+t", "mod+n", "mod+shift+n", "mod+Tab", "mod+shift+Tab", "mod+PageDown", "mod+PageUp", "alt+F4", "mod+shift+q"];
// what input methods take: switching (Ctrl+Space, ⌘Space), Chinese/English
// punctuation (Ctrl+. in Microsoft Pinyin and fcitx), full / half width (Shift+Space)
const IME = ["ctrl+ ", "mod+ ", "ctrl+.", "shift+ ", "ctrl+shift+ "];

const reservedSet = (mac: boolean) => new Set((mac ? RESERVED_MAC : RESERVED_PC).map((k) => canonical(k, mac)));

export function reservedInTab(keys: string, mac: boolean): boolean {
  return reservedSet(mac).has(canonical(keys, mac));
}

export function imeKey(keys: string, mac: boolean): boolean {
  return IME.map((k) => canonical(k, mac)).includes(canonical(keys, mac));
}

/** Whether a binding holds in this scene. */
export function holds(binding: Binding, ctx: KeyContext): boolean {
  if (ctx.layer && !binding.inLayer) return false;
  const when = binding.when ?? {};
  return (Object.keys(when) as (keyof When)[]).every((k) => when[k] === undefined || when[k] === ctx[k]);
}

const isChord = (b: Binding) => parseLeader(b.keys) === null && b.keys !== ESC_ESC;

/** The command a chord runs here and now, null when none can (the key goes on to the browser). */
export function chordCommand(bindings: Binding[], chord: string, ctx: KeyContext, available: (id: string) => boolean): string | null {
  const key = canonical(chord, ctx.mac);
  const hit = bindings.find((b) => isChord(b) && canonical(b.keys, ctx.mac) === key && holds(b, ctx) && available(b.command));
  return hit?.command ?? null;
}

/** The command a second Esc runs (Esc Esc), null when none can. */
export function escapeCommand(bindings: Binding[], ctx: KeyContext, available: (id: string) => boolean): string | null {
  const hit = bindings.find((b) => b.keys === ESC_ESC && holds(b, { ...ctx, layer: false }) && available(b.command));
  return hit?.command ?? null;
}

/** The space menu's tree, from the table's sequences: top-level keys first, then the groups, in the table's order. */
export function leaderTree(bindings: Binding[]): KeyNode[] {
  const top: KeyNode[] = [];
  const groups = new Map<string, KeyNode>();
  for (const b of bindings) {
    const seq = parseLeader(b.keys);
    if (!seq) continue;
    const label = COMMANDS[b.command] ?? b.command;
    if (seq.length === 1) {
      if (!top.some((n) => n.key === seq[0])) top.push({ key: seq[0]!, label, command: b.command });
      continue;
    }
    const [g, k] = seq as [string, string];
    let group = groups.get(g);
    if (!group) {
      group = { key: g, label: GROUPS[g] ?? g, children: [] };
      groups.set(g, group);
    }
    if (!group.children!.some((n) => n.key === k)) group.children!.push({ key: k, label, command: b.command });
  }
  return [...top.filter((n) => !groups.has(n.key)), ...groups.values()];
}

/** The keys that run a command in this window, shown: chords first, then the space menu's (when it is on). */
export function keysFor(command: string, bindings: Binding[], ctx: Pick<KeyContext, "app" | "mac">, leader: boolean): string[] {
  const mine = bindings.filter((b) => b.command === command);
  // the window decides (the app, the platform); the moment — typing or not — does not
  const usable = (b: Binding) => {
    const when = b.when ?? {};
    return (when.app === undefined || when.app === ctx.app) && (when.mac === undefined || when.mac === ctx.mac);
  };
  const chords = mine.filter((b) => parseLeader(b.keys) === null && usable(b));
  const seqs = leader ? mine.filter((b) => parseLeader(b.keys) !== null) : [];
  return [...chords, ...seqs].map((b) => formatKeys(b.keys, ctx.mac));
}

// the tabs' Ctrl+Tab have no space-menu keys of their own; they belong with SPC b
const GROUP_OF: Record<string, string> = { "tab.recent": "b", "tab.recentBack": "b" };

/** The space-menu group a command belongs with ("" for the top level): where its shipped `SPC` keys put it. */
export function commandGroup(command: string): string {
  if (GROUP_OF[command] !== undefined) return GROUP_OF[command]!;
  const seq = DEFAULT_BINDINGS.map((b) => (b.command === command ? parseLeader(b.keys) : null)).find((s) => s !== null);
  return seq && seq.length === 2 ? seq[0]! : "";
}
