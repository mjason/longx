// The space menu as a pure state machine: one key in, the next state and
// what the page should do. The page decides the facts (is the person
// typing, is a dialog or popover open, is an IME composing) and carries the
// action out; everything here is testable without a DOM.
import { lookup, nodeAvailable, type KeyNode } from "./keymap";

export type KeyState = { open: boolean; sequence: string[] };
export const CLOSED: KeyState = { open: false, sequence: [] };

export type KeyInput = {
  key: string;
  ctrl: boolean;
  meta: boolean;
  alt: boolean;
  /** an IME is composing: the key is the IME's */
  composing: boolean;
  /** focus is in a text field (an input, a textarea, the code editor) */
  typing: boolean;
  /** a dialog, a popover or a menu is open: its keys are its own */
  layerOpen: boolean;
  /** focus is on a control the person reached by keyboard, which space presses */
  nativeSpace: boolean;
};

export type KeyAction =
  /** not ours: the browser and the page go on as usual */
  | { type: "none" }
  /** ours, nothing to do (shift pressed on its way to "T") */
  | { type: "consume" }
  | { type: "open" }
  | { type: "descend" }
  | { type: "back" }
  | { type: "close" }
  /** the menu closes and the chord goes on to the browser (⌘K, ⌘S) */
  | { type: "close-pass" }
  | { type: "run"; command: string }
  /** a key with nothing (available) under it: the menu stays and shows it */
  | { type: "unknown" }
  /** escape in a text field: focus leaves it, the space menu is a key away */
  | { type: "leave-input" };

const MODIFIERS = new Set(["Shift", "Control", "Alt", "Meta", "CapsLock", "AltGraph"]);

export function press(
  state: KeyState,
  input: KeyInput,
  tree: KeyNode[],
  available: (id: string) => boolean,
): { state: KeyState; action: KeyAction } {
  const stay = (action: KeyAction) => ({ state, action });
  if (input.composing || input.key === "Process" || input.key === "Unidentified") return stay({ type: "none" });

  if (!state.open) {
    if (input.typing) {
      return input.key === "Escape" && !input.layerOpen ? stay({ type: "leave-input" }) : stay({ type: "none" });
    }
    const bare = !input.ctrl && !input.meta && !input.alt;
    if (input.key === " " && bare && !input.layerOpen && !input.nativeSpace) {
      return { state: { open: true, sequence: [] }, action: { type: "open" } };
    }
    return stay({ type: "none" });
  }

  if (MODIFIERS.has(input.key)) return stay({ type: "consume" });
  if (input.ctrl || input.meta) return { state: CLOSED, action: { type: "close-pass" } };
  if (input.key === "Escape") return { state: CLOSED, action: { type: "close" } };
  if (input.key === "Backspace") {
    return state.sequence.length === 0
      ? { state: CLOSED, action: { type: "close" } }
      : { state: { open: true, sequence: state.sequence.slice(0, -1) }, action: { type: "back" } };
  }

  const next = [...state.sequence, input.key];
  const node = lookup(tree, next);
  if (!node || !nodeAvailable(node, available)) return stay({ type: "unknown" });
  if (node.command) return { state: CLOSED, action: { type: "run", command: node.command } };
  return { state: { open: true, sequence: next }, action: { type: "descend" } };
}
