// How keys are written in the key table and shown on the page. A chord is
// modifiers and a key joined by "+": `mod` is ⌘ on a Mac and Ctrl
// elsewhere, `ctrl` the Control key itself (the same as `mod` off a Mac),
// then `alt`, `shift`; the key is a letter or digit by its key cap (⌥A
// types å on a Mac, the chord is still alt+a), else `KeyboardEvent.key`
// (ArrowDown, Tab, PageDown, Escape). A space-menu sequence is "SPC a s";
// "Escape Escape" is Esc pressed twice.

const MODIFIER_KEYS = new Set(["Shift", "Control", "Alt", "Meta", "CapsLock", "AltGraph", "Fn", "OS"]);
const ORDER = ["mod", "ctrl", "meta", "alt", "shift"];

export type KeyEventLike = { key: string; code: string; metaKey: boolean; ctrlKey: boolean; altKey: boolean; shiftKey: boolean };

export function isMacPlatform(): boolean {
  if (typeof navigator === "undefined") return false;
  const platform = (navigator as Navigator & { userAgentData?: { platform?: string } }).userAgentData?.platform ?? navigator.platform ?? "";
  return /mac|iphone|ipad|ipod/i.test(platform);
}

/** The key an event means: a chord ("mod+k") when mod, ctrl or alt is held, else the character or key name ("T", "?", " ", "Escape"); null for a modifier alone. */
export function eventChord(e: KeyEventLike, mac: boolean): string | null {
  if (MODIFIER_KEYS.has(e.key)) return null;
  const mods: string[] = [];
  if (mac ? e.metaKey : e.ctrlKey) mods.push("mod");
  if (mac && e.ctrlKey) mods.push("ctrl");
  if (!mac && e.metaKey) mods.push("meta");
  if (e.altKey) mods.push("alt");
  if (mods.length === 0) return e.key;
  if (e.shiftKey) mods.push("shift");
  const letter = /^Key([A-Z])$/.exec(e.code);
  const digit = /^Digit(\d)$/.exec(e.code);
  const key = letter ? letter[1]!.toLowerCase() : digit ? digit[1]! : e.key;
  return [...mods, key].join("+");
}

/** The space menu's keys of a binding ("SPC a s" → ["a", "s"]; SPC is the space bar, TAB the tab key), null for a chord. */
export function parseLeader(keys: string): string[] | null {
  const parts = keys.split(" ");
  if (parts[0] !== "SPC" || parts.length < 2) return null;
  return parts.slice(1).map((p) => (p === "SPC" ? " " : p === "TAB" ? "Tab" : p));
}

/** One spelling for a binding's keys on this platform, to compare with `eventChord`. */
export function canonical(keys: string, mac: boolean): string {
  if (parseLeader(keys) || keys === "Escape Escape") return keys;
  // the last "+" ends the modifiers: "ctrl+ " is Ctrl and the space bar
  const plus = keys.lastIndexOf("+");
  if (plus <= 0) return keys;
  const key = keys.slice(plus + 1);
  const mods = new Set(
    keys
      .slice(0, plus)
      .split("+")
      .map((m) => m.toLowerCase())
      .map((m) => (m === "ctrl" && !mac ? "mod" : m)),
  );
  const name = key.length === 1 ? key.toLowerCase() : key;
  return [...ORDER.filter((m) => mods.has(m)), name].join("+");
}

const MAC_SYMBOL: Record<string, string> = { mod: "⌘", ctrl: "⌃", meta: "⌘", alt: "⌥", shift: "⇧" };
const WORD: Record<string, string> = { mod: "Ctrl", ctrl: "Ctrl", meta: "Win", alt: "Alt", shift: "Shift" };
const KEY_NAME: Record<string, string> = {
  ArrowUp: "↑",
  ArrowDown: "↓",
  ArrowLeft: "←",
  ArrowRight: "→",
  PageDown: "PgDn",
  PageUp: "PgUp",
  Escape: "Esc",
  " ": "Space",
  Backspace: "⌫",
  Enter: "Enter",
};

/** How the page shows a binding's keys: ⌘⇧T on a Mac, Ctrl+Shift+T elsewhere; SPC a s; Esc Esc. */
export function formatKeys(keys: string, mac: boolean): string {
  if (keys === "Escape Escape") return "Esc Esc";
  if (parseLeader(keys)) return keys;
  const parts = canonical(keys, mac).split("+");
  const key = parts.pop()!;
  const shownKey = KEY_NAME[key] ?? (key.length === 1 ? key.toUpperCase() : key);
  if (parts.length === 0) return shownKey;
  return mac ? parts.map((m) => MAC_SYMBOL[m] ?? m).join("") + shownKey : [...parts.map((m) => WORD[m] ?? m), shownKey].join("+");
}
