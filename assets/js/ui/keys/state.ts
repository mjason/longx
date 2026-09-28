// What the page shows about the space menu: whether it is open and how far
// the person got (the which-key panel, the status strip), whether focus is in
// a text field (the strip's hint), the help dialog and the command palette.
import { useSyncExternalStore } from "react";
import { CLOSED, type KeyState } from "@/core/keys/engine";

// `recording`: Settings → 快捷键 is listening for a new key, the dispatcher stands aside
type UiState = { menu: KeyState; flash: number; typing: boolean; help: boolean; palette: boolean; recording: boolean };

let state: UiState = { menu: CLOSED, flash: 0, typing: false, help: false, palette: false, recording: false };
const listeners = new Set<() => void>();

export function updateKeysUi(patch: Partial<UiState>): void {
  state = { ...state, ...patch };
  listeners.forEach((l) => l());
}

export function keysUi(): UiState {
  return state;
}

export function useKeysUi(): UiState {
  return useSyncExternalStore(
    (cb) => {
      listeners.add(cb);
      return () => listeners.delete(cb);
    },
    () => state,
    () => state,
  );
}

const TEXT_INPUTS = new Set(["text", "search", "email", "url", "tel", "password", "number", ""]);

/** Focus is where typing goes: an input, a textarea, the code editor, anything editable. */
export function isTyping(el: Element | null): boolean {
  if (!el || el === document.body || el === document.documentElement) return false;
  if (el instanceof HTMLTextAreaElement || el instanceof HTMLSelectElement) return true;
  if (el instanceof HTMLInputElement) return TEXT_INPUTS.has(el.type);
  if ((el as HTMLElement).isContentEditable) return true;
  return el.closest(".cm-editor") !== null;
}

/** Focus is in the code editor or a select: their Alt+arrows are their own (a line moved, the list opened). */
export function isEditor(el: Element | null): boolean {
  if (!el || el === document.body) return false;
  return el instanceof HTMLSelectElement || el.closest(".cm-editor") !== null;
}

// the installed app's window: Chromium reserves no key there (⌘W, Ctrl+Tab
// reach the page); a browser tab keeps them. `data-app-window` lets a native
// shell or a test say so.
const APP_MODES = ["standalone", "window-controls-overlay", "minimal-ui"];

export function appWindow(): boolean {
  if (typeof window === "undefined") return false;
  if (document.documentElement.hasAttribute("data-app-window")) return true;
  if (typeof window.matchMedia !== "function") return false;
  return APP_MODES.some((m) => window.matchMedia(`(display-mode: ${m})`).matches);
}

// dialogs, menus, a select or a popover's list: their keys are their own
// (tooltips are poppers too, and do not count)
const LAYER =
  '[role="dialog"][data-state="open"], [role="alertdialog"][data-state="open"], [role="menu"][data-state="open"], [data-radix-popper-content-wrapper] [role="listbox"]';

export function layerOpen(): boolean {
  return document.querySelector(LAYER) !== null;
}

const PRESSABLE =
  'button, [role="button"], [role="checkbox"], [role="switch"], [role="radio"], [role="tab"], [role="menuitem"], [role="option"], a[href], summary, input[type="checkbox"], input[type="radio"], input[type="button"], input[type="submit"]';

/** A control reached by keyboard: space presses it, as it always has. One clicked keeps no claim on space. */
export function nativeSpace(el: Element | null): boolean {
  if (!el || el === document.body || !el.matches(PRESSABLE)) return false;
  try {
    return el.matches(":focus-visible");
  } catch {
    return false;
  }
}
