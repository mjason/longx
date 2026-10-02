// The centre of the project window as an IDE's editor area: a row of tabs
// — conversations, files and diffs opened from the tree or the git tool —
// with one active, and a new chat only as the empty-workspace fallback.
// Pure transitions plus a small store
// (remembered per project on this device); DOM-free so the phone app can
// share it.
import { useSyncExternalStore } from "react";

// Tab kinds are plain data: a native client may open a kind in a window of
// its own (an artifact in a WebView, a file in its editor) instead of a tab.
export type Tab =
  | { kind: "chat"; threadId?: string; title?: string }
  | { kind: "settings" }
  | { kind: "file"; path: string; line?: number }
  | { kind: "diff"; path: string; sha: string | null }
  // an html document the agent wrote (`show_html`), or a URL; drawn in a sandboxed frame
  | { kind: "artifact"; id: string; title: string; html?: string; url?: string }
  // a sub-agent's conversation, live (its kernel thread id joins its channel; the row id is its page)
  | { kind: "agent"; threadId: string; rowId: string | null; name: string };
export type WorkbenchState = { tabs: Tab[]; active: string; dirty: string[] };

export const EMPTY_WORKBENCH: WorkbenchState = { tabs: [{ kind: "chat" }], active: "chat", dirty: [] };

export function tabKey(tab: Tab): string {
  switch (tab.kind) {
    case "chat":
      return tab.threadId ? `chat:${tab.threadId}` : "chat";
    case "settings":
      return "settings";
    case "file":
      return `file:${tab.path}`;
    case "diff":
      return `diff:${tab.path}@${tab.sha ?? ""}`;
    case "artifact":
      return `artifact:${tab.id}`;
    case "agent":
      return `agent:${tab.threadId}`;
  }
}

export function openTab(state: WorkbenchState, tab: Tab): WorkbenchState {
  const key = tabKey(tab);
  // The original single chat placeholder becomes the first real conversation
  // tab when a deep link opens; otherwise every workspace would carry a
  // redundant unnamed chat beside its named conversation.
  if (tab.kind === "chat" && tab.threadId && state.tabs.some((t) => t.kind === "chat" && !t.threadId)) {
    const alreadyOpen = state.tabs.some((t) => tabKey(t) === key);
    const tabs = state.tabs.flatMap((t) => {
      if (t.kind === "chat" && !t.threadId) return alreadyOpen ? [] : [tab];
      return tabKey(t) === key ? [tab] : [t];
    });
    return { ...state, tabs, active: key };
  }
  // the same tab opened again takes the new details (a file at another line)
  const tabs = state.tabs.some((t) => tabKey(t) === key) ? state.tabs.map((t) => (tabKey(t) === key ? tab : t)) : [...state.tabs, tab];
  return { ...state, tabs, active: key };
}

export function activate(state: WorkbenchState, key: string): WorkbenchState {
  return state.tabs.some((t) => tabKey(t) === key) ? { ...state, active: key } : state;
}

export function closeTab(state: WorkbenchState, key: string): WorkbenchState {
  if (key === "chat") return state;
  const index = state.tabs.findIndex((t) => tabKey(t) === key);
  if (index === -1) return state;
  if (state.tabs[index]?.kind === "chat" && !state.tabs[index]?.threadId) return state;
  const remaining = state.tabs.filter((_, i) => i !== index);
  const tabs = remaining.length ? remaining : [{ kind: "chat" } as const];
  const active = state.active === key ? tabKey(tabs[Math.min(index, tabs.length - 1)]!) : state.active;
  return { tabs, active, dirty: state.dirty.filter((d) => d !== key) };
}

/** The tab `delta` places away from the active one, wrapping around (SPC b n / SPC b p). */
export function stepTab(state: WorkbenchState, delta: number): WorkbenchState {
  const i = state.tabs.findIndex((t) => tabKey(t) === state.active);
  const n = state.tabs.length;
  const next = state.tabs[(((i + delta) % n) + n) % n]!;
  return activate(state, tabKey(next));
}

/** The key of the tab at a place, 1 = the first tab (SPC 1…9); null past the last. */
export function tabAt(state: WorkbenchState, place: number): string | null {
  const tab = state.tabs[place - 1];
  return tab ? tabKey(tab) : null;
}

export function markDirty(state: WorkbenchState, key: string, dirty: boolean): WorkbenchState {
  const has = state.dirty.includes(key);
  if (dirty === has) return state;
  return { ...state, dirty: dirty ? [...state.dirty, key] : state.dirty.filter((d) => d !== key) };
}

/** A file was renamed / moved: its tabs follow. */
export function renamePath(state: WorkbenchState, from: string, to: string): WorkbenchState {
  const move = (tab: Tab): Tab => ((tab.kind === "file" || tab.kind === "diff") && tab.path === from ? { ...tab, path: to } : tab);
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
    if (tabs.length === 0) return EMPTY_WORKBENCH;
    const state: WorkbenchState = {
      tabs,
      active: tabKey(tabs[0]!),
      dirty: [],
    };
    return typeof parsed.active === "string" ? activate(state, parsed.active) : state;
  } catch {
    return EMPTY_WORKBENCH;
  }
}

export type WorkbenchStore = {
  get: () => WorkbenchState;
  activeKey: () => string;
  subscribe: (cb: () => void) => () => void;
  open: (tab: Tab) => void;
  activate: (key: string) => void;
  close: (key: string) => void;
  markDirty: (key: string, dirty: boolean) => void;
  renamePath: (from: string, to: string) => void;
  /** the tab active before this one (SPC TAB) */
  back: () => void;
  /** Ctrl+Tab / Ctrl+Shift+Tab: the next or previous tab by last use, while Ctrl is held */
  cycle: (delta: number) => void;
  /** Ctrl let go: the tab reached is the newest */
  endCycle: () => void;
  /** the last tab closed, open again (SPC b u) */
  reopen: () => void;
  canReopen: () => boolean;
};

export function createWorkbenchStore(storage: Storage | null, key: string): WorkbenchStore {
  let state = load(storage, key);
  // this session's memory, not the device's: the tabs by last use (newest
  // first), the tabs closed, and a Ctrl+Tab walk under way
  let recent: string[] = [state.active];
  const closed: Tab[] = [];
  let walk: { order: string[]; at: number } | null = null;
  const listeners = new Set<() => void>();
  const touch = (key: string) => {
    recent = [key, ...recent.filter((k) => k !== key)];
  };
  const set = (next: WorkbenchState) => {
    if (next === state) return;
    if (next.active !== state.active && !walk) touch(next.active);
    state = next;
    try {
      // dirty flags are not remembered: the content they describe is not
      // either; nor are artifacts — their html lives in the thread, whose row
      // reopens them (and would not fit the device's storage)
      storage?.setItem(key, JSON.stringify({ tabs: state.tabs.filter((t) => t.kind !== "artifact"), active: state.active }));
    } catch {
      /* private mode etc. */
    }
    listeners.forEach((l) => l());
  };
  return {
    get: () => state,
    activeKey: () => state.active,
    subscribe: (cb) => {
      listeners.add(cb);
      return () => listeners.delete(cb);
    },
    open: (tab) => set(openTab(state, tab)),
    activate: (k) => set(activate(state, k)),
    close: (k) => {
      const tab = state.tabs.find((t) => tabKey(t) === k);
      const next = closeTab(state, k);
      if (tab && next !== state) closed.push(tab);
      set(next);
    },
    back: () => {
      const previous = recent.find((k) => k !== state.active && state.tabs.some((t) => tabKey(t) === k));
      if (previous) set(activate(state, previous));
    },
    cycle: (delta) => {
      if (!walk) {
        const open = new Set(state.tabs.map(tabKey));
        // by last use; a tab never used yet (restored from the device) after them, in the bar's order
        const order = [...recent.filter((k) => open.has(k)), ...state.tabs.map(tabKey).filter((k) => !recent.includes(k))];
        walk = { order, at: order.indexOf(state.active) };
      }
      const n = walk.order.length;
      if (n < 2) return;
      walk.at = (((walk.at + delta) % n) + n) % n;
      set(activate(state, walk.order[walk.at]!));
    },
    endCycle: () => {
      if (!walk) return;
      walk = null;
      touch(state.active);
    },
    reopen: () => {
      const tab = closed.pop();
      if (tab) set(openTab(state, tab));
    },
    canReopen: () => closed.length > 0,
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
  return {
    ...state,
    activeKey: s.activeKey,
    open: s.open,
    activate: s.activate,
    close: s.close,
    markDirty: s.markDirty,
    renamePath: s.renamePath,
    back: s.back,
    cycle: s.cycle,
    endCycle: s.endCycle,
    reopen: s.reopen,
    canReopen: s.canReopen,
  };
}

export function _resetWorkbenchForTests() {
  stores.clear();
}
