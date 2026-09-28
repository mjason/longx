// The person's own keys, per device (Settings → 快捷键): a command's keys
// replaced as a whole, kept in localStorage. A key a browser tab keeps for
// itself (⌘W, Ctrl+Tab) is taken as the installed app's; a key an input
// method uses, or one another command holds in the same scene, is refused.
import { useSyncExternalStore } from "react";
import { commandTitle } from "./commands";
import { DEFAULT_BINDINGS, holds, imeKey, reservedInTab, type Binding, type KeyContext } from "./bindings";
import { canonical, isMacPlatform, parseLeader } from "./notation";

export type Overrides = Record<string, string[]>;

const KEY = "longx:keys";
const listeners = new Set<() => void>();
let cache: { raw: string | null; value: Overrides } = { raw: null, value: {} };

export function loadOverrides(): Overrides {
  let raw: string | null = null;
  try {
    raw = localStorage.getItem(KEY);
  } catch {
    return {};
  }
  if (raw === cache.raw) return cache.value;
  let value: Overrides = {};
  try {
    const parsed = raw ? (JSON.parse(raw) as unknown) : {};
    if (parsed && typeof parsed === "object") {
      value = Object.fromEntries(
        Object.entries(parsed as Record<string, unknown>).filter(
          (e): e is [string, string[]] => Array.isArray(e[1]) && e[1].every((k) => typeof k === "string"),
        ),
      );
    }
  } catch {
    value = {};
  }
  cache = { raw, value };
  return value;
}

function save(next: Overrides): void {
  try {
    localStorage.setItem(KEY, JSON.stringify(next));
  } catch {
    /* private mode */
  }
  listeners.forEach((l) => l());
}

/** A command's keys, replaced; null gives it its shipped keys back. */
export function setCommandKeys(command: string, keys: string[] | null): void {
  const next = { ...loadOverrides() };
  if (keys === null) delete next[command];
  else next[command] = keys;
  save(next);
}

export function resetAllKeys(): void {
  save({});
}

/** The table in force: the shipped one with the person's commands replaced. */
export function effectiveBindings(defaults: Binding[], overrides: Overrides, mac: boolean): Binding[] {
  const replaced = new Set(Object.keys(overrides));
  const own = Object.entries(overrides).flatMap(([command, keys]) =>
    keys.map((k): Binding => (parseLeader(k) === null && k !== "Escape Escape" && reservedInTab(k, mac) ? { keys: k, command, when: { app: true } } : { keys: k, command })),
  );
  return [...defaults.filter((b) => !replaced.has(b.command)), ...own];
}

export function currentBindings(): Binding[] {
  return effectiveBindings(DEFAULT_BINDINGS, loadOverrides(), isMacPlatform());
}

let bindingsCache: { overrides: Overrides; value: Binding[] } | null = null;

/** The table in force, re-rendering when the person changes a key. */
export function useBindings(): Binding[] {
  return useSyncExternalStore(
    (cb) => {
      listeners.add(cb);
      return () => listeners.delete(cb);
    },
    () => {
      const overrides = loadOverrides();
      if (!bindingsCache || bindingsCache.overrides !== overrides) bindingsCache = { overrides, value: currentBindings() };
      return bindingsCache.value;
    },
    () => DEFAULT_BINDINGS,
  );
}

export type Validation = { ok: true; appOnly: boolean } | { ok: false; reason: string };

// every scene a binding of these keys could meet
const SCENES: Omit<KeyContext, "mac">[] = [false, true].flatMap((app) =>
  [false, true].flatMap((typing) => [false, true].map((editor) => ({ app, typing, editor, layer: false }))),
);

/** Whether `keys` may be bound to `command`: not an input method's, not another command's where both would hold. */
export function validateKeys(keys: string, command: string, bindings: Binding[], mac: boolean): Validation {
  if (imeKey(keys, mac)) return { ok: false, reason: "输入法在用这个键（切换输入法或中英文标点），换一个" };
  const appOnly = parseLeader(keys) === null && keys !== "Escape Escape" && reservedInTab(keys, mac);
  const mine: Binding = appOnly ? { keys, command, when: { app: true } } : { keys, command };
  const key = canonical(keys, mac);
  for (const other of bindings) {
    if (other.command === command || canonical(other.keys, mac) !== key) continue;
    const clash = SCENES.some((scene) => holds(mine, { ...scene, mac }) && holds(other, { ...scene, mac }));
    if (clash) return { ok: false, reason: `已经是「${commandTitle(other.command)}」的快捷键` };
  }
  return { ok: true, appOnly };
}
