// The project window's frame state: which tool window is open and how wide
// the docked panel is. Pure transitions + a tiny store so React (web) and
// the phone app can share it; the panel width is remembered per device.
import { useSyncExternalStore } from "react";

export type Tool = "threads" | "git" | "process" | "history" | "agents" | "files";
export const TOOLS: Tool[] = ["threads", "git", "process", "history", "agents", "files"];

export type FrameState = { tool: Tool | null; panelWidth: number };

export const MIN_PANEL = 240;
export const MAX_PANEL = 560;
export const DEFAULT_FRAME: FrameState = { tool: "threads", panelWidth: 320 };

export function toggleTool(state: FrameState, tool: Tool): FrameState {
  return { ...state, tool: state.tool === tool ? null : tool };
}

export function openTool(state: FrameState, tool: Tool): FrameState {
  return { ...state, tool };
}

export function closeTool(state: FrameState): FrameState {
  return { ...state, tool: null };
}

export function resizePanel(state: FrameState, width: number): FrameState {
  return { ...state, panelWidth: Math.min(MAX_PANEL, Math.max(MIN_PANEL, Math.round(width))) };
}

/** ⌘/Ctrl + 1..6 → a tool; null when the key is not a frame shortcut. */
export function toolForShortcut(key: string): Tool | null {
  const n = Number.parseInt(key, 10);
  return n >= 1 && n <= TOOLS.length ? TOOLS[n - 1]! : null;
}

// ---- store ---------------------------------------------------------------

const KEY = "longx:frame";
type Storage = { getItem(k: string): string | null; setItem(k: string, v: string): void };

function load(storage: Storage | null): FrameState {
  try {
    const raw = storage?.getItem(KEY);
    if (!raw) return DEFAULT_FRAME;
    const parsed = JSON.parse(raw) as Partial<FrameState>;
    return {
      tool: TOOLS.includes(parsed.tool as Tool) ? (parsed.tool as Tool) : parsed.tool === null ? null : DEFAULT_FRAME.tool,
      panelWidth: typeof parsed.panelWidth === "number" ? resizePanel(DEFAULT_FRAME, parsed.panelWidth).panelWidth : DEFAULT_FRAME.panelWidth,
    };
  } catch {
    return DEFAULT_FRAME;
  }
}

export function createFrameStore(storage: Storage | null) {
  let state = load(storage);
  const listeners = new Set<() => void>();
  const set = (next: FrameState) => {
    state = next;
    try {
      storage?.setItem(KEY, JSON.stringify(next));
    } catch {
      /* ignore */
    }
    listeners.forEach((l) => l());
  };
  return {
    get: () => state,
    subscribe: (l: () => void) => {
      listeners.add(l);
      return () => listeners.delete(l);
    },
    toggle: (tool: Tool) => set(toggleTool(state, tool)),
    open: (tool: Tool) => set(openTool(state, tool)),
    close: () => set(closeTool(state)),
    resize: (width: number) => set(resizePanel(state, width)),
  };
}

export type FrameStore = ReturnType<typeof createFrameStore>;

let store: FrameStore | null = null;

export function frameStore(): FrameStore {
  if (!store) {
    let storage: Storage | null = null;
    try {
      storage = typeof localStorage !== "undefined" ? localStorage : null;
    } catch {
      storage = null;
    }
    store = createFrameStore(storage);
  }
  return store;
}

/** Tests: forget the singleton so each test starts from storage. */
export function _resetFrameStoreForTests() {
  store = null;
}

export function useFrame(): FrameState & Omit<FrameStore, "get" | "subscribe"> {
  const s = frameStore();
  const state = useSyncExternalStore(s.subscribe, s.get, s.get);
  return { ...state, toggle: s.toggle, open: s.open, close: s.close, resize: s.resize };
}
