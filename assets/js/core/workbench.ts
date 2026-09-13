// The centre of the project window as an IDE's editor area: a row of tabs
// — the chat first and always, then files and diffs opened from the tree
// or the git tool — with one active. Pure transitions plus a small store
// (remembered per project on this device); DOM-free so the phone app can
// share it.
import { useSyncExternalStore } from "react";

export type Tab = { kind: "chat" } | { kind: "file"; path: string } | { kind: "diff"; path: string; sha: string | null };
export type WorkbenchState = { tabs: Tab[]; active: string; dirty: string[] };

export const EMPTY_WORKBENCH: WorkbenchState = { tabs: [{ kind: "chat" }], active: "chat", dirty: [] };

export function tabKey(tab: Tab): string {
  switch (tab.kind) {
    case "chat":
      return "chat";
    case "file":
      return `file:${tab.path}`;
    case "diff":
      return `diff:${tab.path}@${tab.sha ?? ""}`;
  }
}

export function openTab(state: WorkbenchState, tab: Tab): WorkbenchState {
  const key = tabKey(tab);
  const tabs = state.tabs.some((t) => tabKey(t) === key) ? state.tabs : [...state.tabs, tab];
  return { ...state, tabs, active: key };
}

export function activate(state: WorkbenchState, key: string): WorkbenchState {
  return state.tabs.some((t) => tabKey(t) === key) ? { ...state, active: key } : state;
}

export function closeTab(state: WorkbenchState, key: string): WorkbenchState {
  if (key === "chat") return state;
  const index = state.tabs.findIndex((t) => tabKey(t) === key);
  if (index === -1) return state;
  const tabs = state.tabs.filter((_, i) => i !== index);
  const active = state.active === key ? tabKey(tabs[Math.min(index, tabs.length - 1)]!) : state.active;
  return { tabs, active, dirty: state.dirty.filter((d) => d !== key) };
}

export function markDirty(state: WorkbenchState, key: string, dirty: boolean): WorkbenchState {
  const has = state.dirty.includes(key);
  if (dirty === has) return state;
  return { ...state, dirty: dirty ? [...state.dirty, key] : state.dirty.filter((d) => d !== key) };
}

/** A file was renamed / moved: its tabs follow. */
export function renamePath(state: WorkbenchState, from: string, to: string): WorkbenchState {
  const move = (tab: Tab): Tab => (tab.kind !== "chat" && tab.path === from ? { ...tab, path: to } : tab);
  const keys = new Map(state.tabs.map((t) => [tabKey(t), tabKey(move(t))]));
  return {
    tabs: state.tabs.map(move),
    active: keys.get(state.active) ?? state.active,
    dirty: state.dirty.map((d) => keys.get(d) ?? d),
  };
}

// ---- store ---------------------------------------------------------------

type Storage = { getItem(k: string): string | null; setItem(k: string, v: string): void };

function load(storage: Storage | null, key: string): WorkbenchState {
  try {
    const raw = storage?.getItem(key);
    if (!raw) return EMPTY_WORKBENCH;
    const parsed = JSON.parse(raw) as Partial<WorkbenchState>;
    const tabs = Array.isArray(parsed.tabs) ? parsed.tabs.filter((t): t is Tab => t && typeof t === "object" && "kind" in t) : [];
    const state: WorkbenchState = { tabs: [{ kind: "chat" }, ...tabs.filter((t) => t.kind !== "chat")], active: "chat", dirty: [] };
    return typeof parsed.active === "string" ? activate(state, parsed.active) : state;
  } catch {
    return EMPTY_WORKBENCH;
  }
}

export type WorkbenchStore = {
  get: () => WorkbenchState;
  subscribe: (cb: () => void) => () => void;
  open: (tab: Tab) => void;
  activate: (key: string) => void;
  close: (key: string) => void;
  markDirty: (key: string, dirty: boolean) => void;
  renamePath: (from: string, to: string) => void;
};

export function createWorkbenchStore(storage: Storage | null, key: string): WorkbenchStore {
  let state = load(storage, key);
  const listeners = new Set<() => void>();
  const set = (next: WorkbenchState) => {
    if (next === state) return;
    state = next;
    try {
      // dirty flags are not remembered: the content they describe is not either
      storage?.setItem(key, JSON.stringify({ tabs: state.tabs, active: state.active }));
    } catch {
      /* private mode etc. */
    }
    listeners.forEach((l) => l());
  };
  return {
    get: () => state,
    subscribe: (cb) => {
      listeners.add(cb);
      return () => listeners.delete(cb);
    },
    open: (tab) => set(openTab(state, tab)),
    activate: (k) => set(activate(state, k)),
    close: (k) => set(closeTab(state, k)),
    markDirty: (k, dirty) => set(markDirty(state, k, dirty)),
    renamePath: (from, to) => set(renamePath(state, from, to)),
  };
}

const stores = new Map<string, WorkbenchStore>();

function storeFor(projectId: string): WorkbenchStore {
  let store = stores.get(projectId);
  if (!store) {
    const storage = typeof localStorage === "undefined" ? null : localStorage;
    store = createWorkbenchStore(storage, `longx:workbench:${projectId}`);
    stores.set(projectId, store);
  }
  return store;
}

export function useWorkbench(projectId: string): WorkbenchState & Omit<WorkbenchStore, "get" | "subscribe"> {
  const s = storeFor(projectId);
  const state = useSyncExternalStore(s.subscribe, s.get, s.get);
  return { ...state, open: s.open, activate: s.activate, close: s.close, markDirty: s.markDirty, renamePath: s.renamePath };
}

export function _resetWorkbenchForTests() {
  stores.clear();
}
